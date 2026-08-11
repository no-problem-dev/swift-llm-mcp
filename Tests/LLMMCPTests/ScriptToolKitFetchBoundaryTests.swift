#if canImport(JavaScriptCore)
import Testing
import Foundation
import HTTPTransport
import LLMTool
@testable import LLMMCP

// MARK: - ios.fetch Host Allowlist Tests

/// What a script can reach over the network.
///
/// Every case asserts on two things: what the script got back, and whether the request was
/// made at all. A refusal that still sends the request is not a boundary — the metadata
/// endpoint has already been read by the time the model is told no.
@Suite("ScriptBridge Fetch Boundary")
struct ScriptToolKitFetchBoundaryTests {

    // MARK: - Test Doubles

    /// Answers every request with the same page and records what it was asked for.
    private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var sentURLs: [URL] = []
        private let body: String

        init(body: String = "PAGE BODY") {
            self.body = body
        }

        var requestedURLs: [URL] {
            lock.withLock { sentURLs }
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            lock.withLock { sentURLs.append(request.url) }
            return HTTPResponse(status: 200, headers: [:], body: Data(body.utf8))
        }
    }

    // MARK: - Helpers

    private func makeToolKit(
        allowedHosts: [String]?,
        transport: RecordingTransport
    ) -> ScriptToolKit {
        ScriptToolKit(
            bridge: ScriptBridge(
                allowedHosts: allowedHosts,
                workingDirectory: FileManager.default.temporaryDirectory.path,
                transport: transport
            )
        )
    }

    private func run(_ code: String, on toolkit: ScriptToolKit) async throws -> String {
        let arguments = try JSONSerialization.data(withJSONObject: ["code": code])
        return try await toolkit.tool(named: "run_script")!.execute(with: arguments).stringValue
    }

    private func fetch(_ url: String, on toolkit: ScriptToolKit) async throws -> String {
        try await run("ios.fetch(\"\(url)\")", on: toolkit)
    }

    // MARK: - Blocked Hosts

    @Test("A host outside the allowlist is refused and never requested")
    func hostOutsideAllowlistIsRefused() async throws {
        let transport = RecordingTransport()
        let toolkit = makeToolKit(allowedHosts: ["example.com"], transport: transport)

        let output = try await fetch("http://169.254.169.254/latest/meta-data/", on: toolkit)

        #expect(output.contains("PAGE BODY") == false)
        #expect(output.contains("[error]"))
        #expect(transport.requestedURLs.isEmpty)
    }

    @Test("An internal service on localhost is refused and never requested")
    func localhostIsRefused() async throws {
        let transport = RecordingTransport()
        let toolkit = makeToolKit(allowedHosts: ["example.com"], transport: transport)

        let output = try await fetch("http://localhost:8080/admin", on: toolkit)

        #expect(output.contains("PAGE BODY") == false)
        #expect(output.contains("[error]"))
        #expect(transport.requestedURLs.isEmpty)
    }

    @Test("A host that merely contains an allowed host is refused")
    func lookalikeHostsAreRefused() async throws {
        let transport = RecordingTransport()
        let toolkit = makeToolKit(allowedHosts: ["example.com"], transport: transport)

        // Same string, no label boundary: a suffix match and a prefix match.
        for url in ["https://notexample.com/x", "https://example.com.evil.net/x"] {
            let output = try await fetch(url, on: toolkit)
            #expect(output.contains("PAGE BODY") == false, "\(url) was fetched")
            #expect(output.contains("[error]"), "\(url) was not refused")
        }

        #expect(transport.requestedURLs.isEmpty)
    }

    @Test("A scheme other than http or https is refused")
    func nonHTTPSchemesAreRefused() async throws {
        let transport = RecordingTransport()
        let toolkit = makeToolKit(allowedHosts: ["example.com"], transport: transport)

        for url in ["file:///etc/passwd", "ftp://example.com/secret"] {
            let output = try await fetch(url, on: toolkit)
            #expect(output.contains("PAGE BODY") == false, "\(url) was fetched")
            #expect(output.contains("[error]"), "\(url) was not refused")
        }

        #expect(transport.requestedURLs.isEmpty)
    }

    @Test("A scheme other than http or https is refused even with no allowlist")
    func nonHTTPSchemesAreRefusedWithoutAllowlist() async throws {
        let transport = RecordingTransport()
        let toolkit = makeToolKit(allowedHosts: nil, transport: transport)

        let output = try await fetch("file:///etc/passwd", on: toolkit)

        #expect(output.contains("PAGE BODY") == false)
        #expect(output.contains("[error]"))
        #expect(transport.requestedURLs.isEmpty)
    }

    // MARK: - Allowed Hosts

    @Test("An allowed host, and a subdomain of it, are fetched")
    func allowedHostAndSubdomainAreFetched() async throws {
        let transport = RecordingTransport()
        let toolkit = makeToolKit(allowedHosts: ["example.com"], transport: transport)

        let exact = try await fetch("https://example.com/page", on: toolkit)
        #expect(exact.contains("PAGE BODY"))

        let subdomain = try await fetch("https://api.example.com/v1/items", on: toolkit)
        #expect(subdomain.contains("PAGE BODY"))

        #expect(transport.requestedURLs.count == 2)
    }

    @Test("Host matching ignores case on both sides")
    func hostMatchingIsCaseInsensitive() async throws {
        let transport = RecordingTransport()
        let toolkit = makeToolKit(allowedHosts: ["Example.COM"], transport: transport)

        let output = try await fetch("https://EXAMPLE.com/page", on: toolkit)

        #expect(output.contains("PAGE BODY"))
        #expect(transport.requestedURLs.count == 1)
    }

    @Test("No allowlist leaves the network open, as the default documents")
    func absentAllowlistReachesAnyHost() async throws {
        let transport = RecordingTransport()
        let toolkit = makeToolKit(allowedHosts: nil, transport: transport)

        let output = try await fetch("http://localhost:8080/admin", on: toolkit)

        #expect(output.contains("PAGE BODY"))
        #expect(transport.requestedURLs.count == 1)
    }
}
#endif
