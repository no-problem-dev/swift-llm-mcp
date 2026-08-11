#if os(macOS)
import Testing
import Foundation
import MCP
@testable import LLMMCP

// MARK: - ProcessTransport Pending Buffer Tests

/// What a consumer of the message stream sees when the child process misbehaves.
///
/// A real child process is launched for each of these, because the buffer being tested only
/// exists in the loop that reads a real pipe.
@Suite("ProcessTransport Pending Buffer")
struct ProcessTransportBufferTests {

    /// Reads the stream to its end and returns the error that ended it, if any.
    private func drain(_ transport: ProcessTransport) async -> (messages: [Data], error: (any Error)?) {
        var messages: [Data] = []
        do {
            for try await message in await transport.receive() {
                messages.append(message)
            }
            return (messages, nil)
        } catch {
            return (messages, error)
        }
    }

    @Test("A server that writes without a newline fails the stream instead of growing the buffer")
    func unterminatedMessageOverLimitFailsTheStream() async throws {
        // A megabyte of zero bytes: no newline anywhere in it, so nothing can ever be framed.
        let transport = ProcessTransport(
            command: "/bin/dd",
            arguments: ["if=/dev/zero", "bs=65536", "count=16"],
            maximumPendingBytes: 64 * 1024
        )

        try await transport.connect()
        let (messages, error) = await drain(transport)
        await transport.disconnect()

        #expect(messages.isEmpty)

        let streamError = try #require(error, "The stream ended cleanly after swallowing a megabyte with no newline")
        // The message has to name the limit, or the operator cannot tell a cap from a crash.
        #expect("\(streamError)".contains("65536"))
    }

    @Test("A complete message under the limit is still delivered")
    func terminatedMessageUnderLimitIsDelivered() async throws {
        let transport = ProcessTransport(
            command: "/bin/echo",
            arguments: [#"{"jsonrpc":"2.0","id":1}"#],
            maximumPendingBytes: 64 * 1024
        )

        try await transport.connect()
        let (messages, error) = await drain(transport)
        await transport.disconnect()

        #expect(error == nil)
        #expect(messages.count == 1)
        #expect(String(data: messages[0], encoding: .utf8) == #"{"jsonrpc":"2.0","id":1}"#)
    }

    @Test("A long message is fine as long as it ends in a newline")
    func largeButTerminatedMessageIsDelivered() async throws {
        // Well over one read from the pipe, so it arrives in pieces and is reassembled.
        let payload = String(repeating: "x", count: 300_000)
        let transport = ProcessTransport(
            command: "/bin/echo",
            arguments: [payload],
            maximumPendingBytes: 1024 * 1024
        )

        try await transport.connect()
        let (messages, error) = await drain(transport)
        await transport.disconnect()

        #expect(error == nil)
        #expect(messages.count == 1)
        #expect(messages.first?.count == payload.count)
    }
}
#endif
