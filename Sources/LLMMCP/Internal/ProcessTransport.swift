#if os(macOS) || os(Linux)
import Foundation
import Logging
import MCP

// MARK: - ProcessTransportError

/// Failures ``ProcessTransport`` raises on its own account, rather than passing on from the
/// child process or the pipes.
internal enum ProcessTransportError: Error, LocalizedError {
    /// The server wrote more than the limit without a newline, so no message could be framed.
    case unterminatedMessageTooLarge(bytes: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .unterminatedMessageTooLarge(let bytes, let limit):
            return """
                The MCP server sent \(bytes) bytes with no newline, past the \(limit)-byte limit \
                for a single message. The connection was closed rather than framing a partial message.
                """
        }
    }
}

// MARK: - ProcessTransport

/// Launches an MCP server as a child process and speaks newline-delimited JSON-RPC over its pipes.
///
/// The SDK's own `StdioTransport` is the server side of this arrangement — it talks over the
/// current process's stdin and stdout. This one is the client side: it owns the child.
///
/// The child's stderr is drained into the logger, which matters because a server that writes
/// diagnostics to stderr would otherwise fill its pipe buffer and deadlock.
internal actor ProcessTransport: Transport {
    // MARK: - ConnectionState

    private enum ConnectionState {
        case disconnected
        case connected(
            process: Process,
            stdin: Pipe,
            stdout: Pipe,
            stderr: Pipe,
            readLoopTask: Task<Void, Never>,
            stderrTask: Task<Void, Never>
        )
    }

    // MARK: - Properties

    public nonisolated let logger: Logger

    private let command: String
    private let arguments: [String]
    private let environment: [String: String]

    /// How many bytes of an unfinished message the read loop will hold before giving up on it.
    private let maximumPendingBytes: Int

    private var state: ConnectionState = .disconnected
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    // MARK: - Initialization

    /// Records what to launch. Nothing runs until ``connect()``.
    ///
    /// - Parameters:
    ///   - command: Absolute path to the executable. Not resolved through `PATH`.
    ///   - arguments: Arguments for it.
    ///   - environment: Variables layered over the parent process environment.
    ///   - logger: Where the child's stderr goes. Defaults to a no-op handler, which
    ///     discards every diagnostic the server writes.
    ///   - maximumPendingBytes: How much of an unterminated message to hold before failing the
    ///     stream. The default leaves room for a large tool result while still bounding a
    ///     server that never emits a newline.
    init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        logger: Logger? = nil,
        maximumPendingBytes: Int = 16 * 1024 * 1024
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.maximumPendingBytes = maximumPendingBytes
        self.logger = logger ?? Logger(
            label: "mcp.transport.process",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )

        // The stream is created once and never replaced, so a transport that has been
        // disconnected cannot be reconnected: its continuation is already finished.
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    // MARK: - Transport Protocol

    /// Starts the child process and the two tasks that drain its stdout and stderr.
    ///
    /// Returns as soon as the process is spawned; a server that exits immediately shows up
    /// later as end-of-stream rather than as an error here. Calling it while connected does nothing.
    ///
    /// - Throws: `MCPError.transportError` when the executable cannot be launched.
    public func connect() async throws {
        guard case .disconnected = state else { return }

        logger.debug("Starting MCP server process", metadata: [
            "command": "\(command)",
            "arguments": "\(arguments)"
        ])

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Inherit the parent environment, then layer the overrides on top. The child sees
        // every variable this process has, including any credentials in it.
        var processEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            processEnvironment[key] = value
        }
        process.environment = processEnvironment

        do {
            try process.run()
            logger.debug("MCP server process started", metadata: ["pid": "\(process.processIdentifier)"])
        } catch {
            logger.error("Failed to start MCP server process", metadata: ["error": "\(error)"])
            throw MCP.MCPError.transportError(error)
        }

        // Held in the state so disconnect can cancel them.
        let readLoopTask = Task {
            await readLoop()
        }

        let stderrTask = Task {
            await monitorStderr()
        }

        state = .connected(
            process: process,
            stdin: stdinPipe,
            stdout: stdoutPipe,
            stderr: stderrPipe,
            readLoopTask: readLoopTask,
            stderrTask: stderrTask
        )
    }

    /// Cancels the reader tasks, closes the pipes and asks the child to stop.
    ///
    /// The child gets SIGTERM, then SIGINT 100 ms later if it is still alive. Neither can be
    /// ignored-proofed — a process that traps both survives this call, and nothing waits for
    /// it to exit, so `disconnect()` can return while the child is still running.
    ///
    /// This is one-way. The message stream is finished here and never restarted, so the
    /// transport cannot be reconnected afterwards.
    public func disconnect() async {
        guard case .connected(let process, let stdin, let stdout, let stderr, let readLoopTask, let stderrTask) = state else {
            return
        }

        logger.debug("Disconnecting MCP server process")

        readLoopTask.cancel()
        stderrTask.cancel()

        messageContinuation.finish()

        stdin.fileHandleForWriting.closeFile()
        stdout.fileHandleForReading.closeFile()
        stderr.fileHandleForReading.closeFile()

        if process.isRunning {
            process.terminate()
            // Give it a moment, then escalate to SIGINT. This is not SIGKILL, so a process
            // that traps both signals keeps running.
            try? await Task.sleep(for: .milliseconds(100))
            if process.isRunning {
                process.interrupt()
            }
        }

        state = .disconnected

        logger.debug("MCP server process disconnected")
    }

    /// Writes one JSON-RPC message to the child's stdin, terminated by a newline.
    ///
    /// The write is synchronous and blocks the actor if the child stops reading its stdin.
    ///
    /// - Throws: `MCPError.internalError` when not connected, `MCPError.transportError`
    ///   when the write fails — which is how a child that has already exited is noticed.
    public func send(_ data: Data) async throws {
        guard case .connected(_, let stdin, _, _, _, _) = state else {
            throw MCP.MCPError.internalError("Transport not connected")
        }

        // Newline-delimited framing: the message must not contain a bare newline itself.
        var messageData = data
        messageData.append(UInt8(ascii: "\n"))

        logger.trace("Sending message", metadata: ["size": "\(data.count)"])

        do {
            try stdin.fileHandleForWriting.write(contentsOf: messageData)
        } catch {
            logger.error("Failed to send message", metadata: ["error": "\(error)"])
            throw MCP.MCPError.transportError(error)
        }
    }

    /// The stream of messages read from the child's stdout, one element per line.
    ///
    /// A single shared stream, so only one consumer receives each message. It finishes on
    /// disconnect or on end-of-stream from the child, and cannot be restarted.
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    // MARK: - Private Methods

    /// Reads the child's stdout and yields one message per newline until cancelled or EOF.
    ///
    /// What has arrived without a terminating newline is held in the pending buffer, capped at
    /// ``maximumPendingBytes``. Past that the stream fails: the frame is not truncated to fit,
    /// because half a JSON-RPC message parsed as a whole one is a wrong answer, and it is not
    /// held either, because a server that never writes a newline would otherwise grow this
    /// until the host runs out of memory. Cancellation is only observed between reads, so a
    /// child that goes quiet leaves this parked in a read.
    private func readLoop() async {
        guard case .connected(_, _, let stdout, _, _, _) = state else { return }

        let fileHandle = stdout.fileHandleForReading
        var pendingData = Data()

        while !Task.isCancelled {
            do {
                // availableData blocks, so it runs off the cooperative pool and the result
                // is bridged back through a continuation.
                let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    DispatchQueue.global().async {
                        let data = fileHandle.availableData
                        continuation.resume(returning: data)
                    }
                }

                if data.isEmpty {
                    // Empty read means EOF: the server process has exited.
                    logger.notice("EOF received from MCP server process")
                    break
                }

                pendingData.append(data)

                // Drain every complete line; whatever is left stays buffered for the next read.
                while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                    let messageData = pendingData[..<newlineIndex]
                    pendingData = pendingData[(newlineIndex + 1)...]

                    if !messageData.isEmpty {
                        logger.trace("Message received", metadata: ["size": "\(messageData.count)"])
                        messageContinuation.yield(Data(messageData))
                    }
                }

                // Checked after draining, so the cap bounds one unfinished message rather
                // than the total traffic.
                if pendingData.count > maximumPendingBytes {
                    let error = ProcessTransportError.unterminatedMessageTooLarge(
                        bytes: pendingData.count,
                        limit: maximumPendingBytes
                    )
                    logger.error("Pending message exceeded the limit", metadata: [
                        "bytes": "\(pendingData.count)",
                        "limit": "\(maximumPendingBytes)"
                    ])
                    messageContinuation.finish(throwing: MCP.MCPError.transportError(error))
                    return
                }
            } catch {
                if !Task.isCancelled {
                    logger.error("Read error occurred", metadata: ["error": "\(error)"])
                }
                break
            }
        }

        messageContinuation.finish()
    }

    /// Drains the child's stderr into the logger until cancelled or EOF.
    ///
    /// Draining is what matters: an undrained stderr pipe fills and blocks the child. Like
    /// ``readLoop()``, the blocking read runs off the cooperative pool and comes back through
    /// a continuation — reading it inline would hold this actor for as long as the child stays
    /// quiet, which is the whole session, and the read loop would never get to run.
    /// Cancellation is only observed between reads.
    private func monitorStderr() async {
        guard case .connected(_, _, _, let stderr, _, _) = state else { return }

        let fileHandle = stderr.fileHandleForReading

        while !Task.isCancelled {
            let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                DispatchQueue.global().async {
                    continuation.resume(returning: fileHandle.availableData)
                }
            }

            if data.isEmpty { break }

            if let message = String(data: data, encoding: .utf8) {
                logger.debug("MCP server stderr", metadata: ["message": "\(message.trimmingCharacters(in: .whitespacesAndNewlines))"])
            }
        }
    }
}
#endif
