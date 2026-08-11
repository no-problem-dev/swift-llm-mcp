// JavaScriptCore is an Apple-platform framework with no counterpart in
// swift-corelibs, so this tool kit -- and the `run_script` tool it vends -- is
// absent on platforms that lack it rather than failing the whole build.
#if canImport(JavaScriptCore)
import Foundation
import HTTPTransport
import StructuredDataCore
import JSONParsing
import JavaScriptCore
import LLMClient
import LLMTool

// MARK: - ScriptToolKit

/// Runs model-written JavaScript in a JavaScriptCore virtual machine.
///
/// Use it for the work no fixed tool covers: reshaping data, transforming text, arithmetic
/// over a fetched document. Each run gets a fresh virtual machine, so nothing carries over
/// between calls — a script cannot leave state for the next one.
///
/// The JavaScript environment is bare: no `require`, no timers, no DOM, and no `async`.
/// What it does have is `console` and the `ios` object supplied by ``ScriptBridge``, whose file
/// access is bounded by the bridge's allowed paths and whose network access is bounded by its
/// allowed hosts. Give the bridge both lists; the default bridge has neither restriction.
///
/// ```swift
/// let tools = ToolSet {
///     ScriptToolKit(
///         bridge: ScriptBridge(
///             allowedPaths: ["/Users/user/Documents"],
///             allowedHosts: ["api.example.com"]
///         ),
///         timeout: 30
///     )
/// }
/// ```
public final class ScriptToolKit: ToolKit, @unchecked Sendable {
    // MARK: - Properties

    public let name: String = "script"

    private let bridge: ScriptBridge

    private let timeout: TimeInterval

    // MARK: - Initialization

    /// Creates the kit.
    ///
    /// - Parameters:
    ///   - bridge: The `ios` API exposed to scripts. The default permits file access anywhere
    ///     this process can reach, and network access to any host.
    ///   - timeout: Seconds before the tool reports a timeout. It is a deadline on the
    ///     reply, not preemption of the script — see the `run_script` tool.
    public init(
        bridge: ScriptBridge = ScriptBridge(),
        timeout: TimeInterval = 30
    ) {
        self.bridge = bridge
        self.timeout = timeout
    }

    // MARK: - ToolKit Protocol

    public var tools: [any Tool] {
        [runScriptTool]
    }

    // MARK: - Tool Definition

    /// The `run_script` tool: evaluate JavaScript and return its console output and final value.
    ///
    /// A JavaScript exception comes back as a `ToolResult.error` rather than a thrown error,
    /// so the model can read the message and correct its code.
    ///
    /// The timeout races the evaluation against a sleep and reports
    /// ``ScriptToolKitError/timeout(seconds:)`` when the sleep wins. JavaScriptCore
    /// evaluation cannot be cancelled, so this bounds when a timeout is *decided*, not when
    /// a runaway script stops: an infinite loop keeps running and keeps the task group open.
    private var runScriptTool: BuiltInTool {
        BuiltInTool(
            name: "run_script",
            description: """
                Execute JavaScript code in a sandboxed environment. \
                Use this for data processing, text transformation, calculations, \
                or any task that requires custom logic beyond what other tools provide. \
                The `ios` object provides bridged APIs: \
                `ios.cwd` (working directory path string), \
                `ios.readFile(path)`, `ios.writeFile(path, content)`, `ios.listFiles(path)`, \
                `ios.fetch(url)`, `ios.log(message)`. \
                Relative paths in file APIs are resolved against `ios.cwd`. \
                The return value of the last expression is captured as the result.
                """,
            inputSchema: .object(
                properties: [
                    "code": .string(
                        description: "JavaScript code to execute. The return value of the last expression becomes the result."
                    ),
                ],
                required: ["code"]
            ),
            annotations: ToolAnnotations(
                title: "Run Script",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(RunScriptInput.self, from: data)

            // Race the evaluation against a sleep; whichever finishes first wins.
            return try await withThrowingTaskGroup(of: ToolResult.self) { group in
                group.addTask { [self] in
                    try await self.executeScript(code: input.code)
                }

                group.addTask { [self] in
                    try await Task.sleep(for: .seconds(self.timeout))
                    throw ScriptToolKitError.timeout(seconds: self.timeout)
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        }
    }

    // MARK: - Script Execution

    /// Evaluates the code in a fresh virtual machine and formats the console output and result.
    ///
    /// Synchronous throughout: `evaluateScript` blocks its thread until the script finishes,
    /// which is why the timeout has to live outside this method.
    private func executeScript(code: String) async throws -> ToolResult {
        // A private virtual machine per run, so nothing leaks between tool calls. Creation
        // and evaluation stay on one thread because JSContext is not thread-safe.
        let vm = JSVirtualMachine()!
        let context = JSContext(virtualMachine: vm)!

        let logBuffer = LogBuffer()

        // JavaScriptCore reports exceptions through this handler rather than by returning nil.
        var scriptError: String?
        context.exceptionHandler = { _, exception in
            scriptError = exception?.toString() ?? "Unknown JavaScript error"
        }

        bridge.install(into: context, logBuffer: logBuffer)
        installConsole(into: context, logBuffer: logBuffer)

        let result = context.evaluateScript(code)

        // An exception discards the console output collected before it.
        if let error = scriptError {
            return .error("Script error: \(error)")
        }

        // Console output first, then the final value.
        var output = ""

        let logs = logBuffer.flush()
        if !logs.isEmpty {
            output += logs.joined(separator: "\n")
            output += "\n"
        }

        // Objects are pretty-printed as JSON with sorted keys; everything else is stringified.
        if let result, !result.isUndefined, !result.isNull {
            let resultString: String
            if result.isObject, let object = result.toObject() {
                resultString = JSONSerializer(options: .init(prettyPrinted: true, sortKeys: true))
                    .string(from: StructuredValue(anyValue: object))
            } else {
                resultString = result.toString()
            }
            output += resultString
        }

        if output.isEmpty {
            return .text("(no output)")
        }

        return .text(output)
    }

    /// Installs `console.log`, `console.warn` and `console.error`, all collected into `logBuffer`.
    ///
    /// Each takes a single argument, unlike the browser's variadic `console.log`, so extra
    /// arguments are dropped.
    private func installConsole(into context: JSContext, logBuffer: LogBuffer) {
        let console = JSValue(newObjectIn: context)!

        let logFn: @convention(block) (JSValue) -> Void = { value in
            logBuffer.append(value.toString())
        }

        let warnFn: @convention(block) (JSValue) -> Void = { value in
            logBuffer.append("[warn] \(value.toString())")
        }

        let errorFn: @convention(block) (JSValue) -> Void = { value in
            logBuffer.append("[error] \(value.toString())")
        }

        console.setObject(
            unsafeBitCast(logFn, to: AnyObject.self),
            forKeyedSubscript: "log" as NSString
        )
        console.setObject(
            unsafeBitCast(warnFn, to: AnyObject.self),
            forKeyedSubscript: "warn" as NSString
        )
        console.setObject(
            unsafeBitCast(errorFn, to: AnyObject.self),
            forKeyedSubscript: "error" as NSString
        )

        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

}

// MARK: - ScriptBridge

/// The `ios` object that scripts use to reach the file system and the network.
///
/// Five members: `ios.cwd`, `ios.readFile(path)`, `ios.writeFile(path, content)`,
/// `ios.listFiles(path)`, `ios.fetch(url)` and `ios.log(message)`.
///
/// Failures are returned as strings that begin with `[error]`, not thrown, because
/// JavaScriptCore blocks cannot throw into the script. A script therefore cannot tell a
/// failure from file content that happens to start with `[error]`.
///
/// `allowedPaths` bounds the file members and `allowedHosts` bounds `ios.fetch`. Both default
/// to `nil`, which is no boundary at all: an unbounded bridge lets a script reach any host this
/// process can, including link-local metadata endpoints and services on localhost.
public final class ScriptBridge: @unchecked Sendable {
    /// Directories scripts may read and write. An empty boundary allows everything.
    private let boundary: PathBoundary

    /// Hosts `ios.fetch` may reach. An empty boundary allows every host.
    private let hostBoundary: HostBoundary

    /// Where relative paths in the file members resolve. Also the value of `ios.cwd`.
    private let workingDirectory: String

    private let fileManager: FileManager

    private let transport: any HTTPTransport

    private let httpTimeout: TimeInterval

    /// Creates a bridge, building a `URLSession`-backed transport unless one is supplied.
    ///
    /// - Parameters:
    ///   - allowedPaths: Directories scripts may touch. A leading `~` is expanded. `nil`
    ///     imposes no boundary, which is reasonable on iOS where the sandbox is the
    ///     boundary, and is not on macOS.
    ///   - allowedHosts: Hosts `ios.fetch` may reach. A subdomain of a listed host is allowed;
    ///     a name that merely ends the same way is not. `nil` imposes no boundary, which lets
    ///     a script reach anything this process can — including link-local metadata endpoints
    ///     and services listening on localhost.
    ///   - workingDirectory: Where relative paths resolve. Defaults to the app's Documents directory.
    ///   - httpTimeout: Per-request timeout for `ios.fetch`, in seconds. It is what bounds how
    ///     long that call blocks the calling thread.
    ///   - transport: Substitute one in tests to avoid real network calls.
    public init(
        allowedPaths: [String]? = nil,
        allowedHosts: [String]? = nil,
        workingDirectory: String? = nil,
        httpTimeout: TimeInterval = 15,
        transport: (any HTTPTransport)? = nil
    ) {
        self.boundary = PathBoundary(allowedPaths: allowedPaths)
        self.hostBoundary = HostBoundary(allowedHosts: allowedHosts)
        self.workingDirectory = workingDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.currentDirectoryPath
        self.fileManager = FileManager.default

        if let transport {
            self.transport = transport
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = httpTimeout
            self.transport = URLSessionTransport(session: URLSession(configuration: config), defaultTimeout: httpTimeout)
        }

        self.httpTimeout = httpTimeout
    }

    /// Resolves a script's path and rejects it if it falls outside the allowed paths.
    ///
    /// Anything not starting with `/` resolves against ``workingDirectory``. The boundary is
    /// the same ``PathBoundary`` ``FileSystemToolKit`` uses, so both kits follow symlinks to
    /// where they really point and both judge containment by path component.
    ///
    /// - Throws: ``ScriptToolKitError/accessDenied(path:)``.
    private func validatePath(_ path: String) throws -> String {
        do {
            return try boundary.resolve(path, workingDirectory: workingDirectory)
        } catch {
            throw ScriptToolKitError.accessDenied(path: error.path)
        }
    }

    /// Installs the `ios` object into a context, routing its log output to `logBuffer`.
    func install(into context: JSContext, logBuffer: LogBuffer) {
        let ios = JSValue(newObjectIn: context)!

        // ios.cwd -> String
        ios.setObject(
            workingDirectory,
            forKeyedSubscript: "cwd" as NSString
        )

        // ios.readFile(path) -> String, or an "[error] ..." string on failure.
        let readFile: @convention(block) (String) -> String = { [self] path in
            do {
                let validPath = try validatePath(path)
                guard let data = fileManager.contents(atPath: validPath),
                      let text = String(data: data, encoding: .utf8)
                else {
                    return "[error] Cannot read file: \(path)"
                }
                return text
            } catch {
                return "[error] \(error.localizedDescription)"
            }
        }

        // ios.writeFile(path, content) -> Bool. Creates parent directories; overwrites
        // without requiring a prior read, unlike FileSystemToolKit's write_file.
        let writeFile: @convention(block) (String, String) -> Bool = { [self] path, content in
            do {
                let validPath = try validatePath(path)
                let parentDir = URL(fileURLWithPath: validPath).deletingLastPathComponent().path
                try fileManager.createDirectory(
                    atPath: parentDir,
                    withIntermediateDirectories: true
                )
                guard let data = content.data(using: .utf8) else { return false }
                try data.write(to: URL(fileURLWithPath: validPath))
                return true
            } catch {
                logBuffer.append("[error] writeFile: \(error.localizedDescription)")
                return false
            }
        }

        // ios.listFiles(path) -> [String]. On failure the array holds one "[error] ..." entry.
        let listFiles: @convention(block) (String) -> [String] = { [self] path in
            do {
                let validPath = try validatePath(path)
                return try fileManager.contentsOfDirectory(atPath: validPath).sorted()
            } catch {
                return ["[error] \(error.localizedDescription)"]
            }
        }

        // ios.fetch(url) -> String. GET only, no headers, and the whole body is returned as
        // text. The host must pass the bridge's allowed hosts, and the scheme must be http or
        // https. JavaScriptCore has no await, so the async call is made synchronous with a
        // semaphore: this blocks the calling thread until the request finishes or the
        // transport's own timeout fires.
        let fetch: @convention(block) (String) -> String = { [self] urlString in
            guard let url = URL(string: urlString) else {
                return "[error] Invalid URL: \(urlString)"
            }

            // Checked before anything is sent: a refusal that still made the request would
            // have already read whatever it was pointed at.
            if let violation = hostBoundary.violation(for: url) {
                return "[error] \(ScriptToolKitError(violation).localizedDescription)"
            }

            // The semaphore is what makes this exclusive, so the unchecked capture is sound.
            nonisolated(unsafe) var resultText = "[error] Request failed"
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) let transport = self.transport
            let timeout = self.httpTimeout

            Task { @Sendable in
                defer { semaphore.signal() }
                do {
                    let response = try await transport.send(HTTPRequest(method: "GET", url: url, timeout: timeout))
                    guard (200...299).contains(response.status) else {
                        resultText = "[error] HTTP \(response.status)"
                        return
                    }
                    resultText = String(data: response.body, encoding: .utf8) ?? "[error] Cannot decode response"
                } catch {
                    resultText = "[error] \(error.localizedDescription)"
                }
            }
            semaphore.wait()

            return resultText
        }

        // ios.log(message). Same buffer as console.log, so output interleaves in call order.
        let log: @convention(block) (String) -> Void = { message in
            logBuffer.append(message)
        }

        ios.setObject(
            unsafeBitCast(readFile, to: AnyObject.self),
            forKeyedSubscript: "readFile" as NSString
        )
        ios.setObject(
            unsafeBitCast(writeFile, to: AnyObject.self),
            forKeyedSubscript: "writeFile" as NSString
        )
        ios.setObject(
            unsafeBitCast(listFiles, to: AnyObject.self),
            forKeyedSubscript: "listFiles" as NSString
        )
        ios.setObject(
            unsafeBitCast(fetch, to: AnyObject.self),
            forKeyedSubscript: "fetch" as NSString
        )
        ios.setObject(
            unsafeBitCast(log, to: AnyObject.self),
            forKeyedSubscript: "log" as NSString
        )

        context.setObject(ios, forKeyedSubscript: "ios" as NSString)
    }
}

// MARK: - LogBuffer

/// Collects a script's log output, guarded by a lock because scripts can log from a
/// bridged callback on another thread.
///
/// Unbounded: a script that logs in a loop grows this until the run ends.
final class LogBuffer: @unchecked Sendable {
    private var logs: [String] = []
    private let lock = NSLock()

    func append(_ message: String) {
        lock.lock()
        logs.append(message)
        lock.unlock()
    }

    /// Returns everything logged so far and empties the buffer.
    func flush() -> [String] {
        lock.lock()
        let result = logs
        logs.removeAll()
        lock.unlock()
        return result
    }
}

// MARK: - Input Types

private struct RunScriptInput: Codable {
    var code: String
}

// MARK: - Errors

/// Failures from ``ScriptToolKit``.
///
/// A JavaScript exception is not one of these — it comes back as a `ToolResult.error`.
public enum ScriptToolKitError: Error, LocalizedError {
    case timeout(seconds: TimeInterval)
    case accessDenied(path: String)
    case hostNotAllowed(host: String, allowedHosts: [String])
    case unsupportedScheme(scheme: String)
    case executionFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let seconds):
            return "Script execution timed out after \(Int(seconds)) seconds"
        case .accessDenied(let path):
            return "Access denied to path: \(path)"
        case .hostNotAllowed(let host, let allowedHosts):
            return "Access denied to host '\(host)'. Allowed hosts: \(allowedHosts.joined(separator: ", "))"
        case .unsupportedScheme(let scheme):
            return "Access denied to scheme '\(scheme)'. ios.fetch supports http and https only."
        case .executionFailed(let message):
            return "Script execution failed: \(message)"
        }
    }
}

extension ScriptToolKitError {
    /// Restates a boundary refusal as the error a script's caller reads.
    init(_ violation: URLOutsideBoundary) {
        switch violation.reason {
        case .unsupportedScheme(let scheme):
            self = .unsupportedScheme(scheme: scheme)
        case .hostNotAllowed(let host):
            self = .hostNotAllowed(host: host, allowedHosts: violation.allowedHosts ?? [])
        }
    }
}

#endif  // canImport(JavaScriptCore)
