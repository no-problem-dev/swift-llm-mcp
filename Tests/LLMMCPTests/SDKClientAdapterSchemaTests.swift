import Testing
import Foundation
import LLMClient
import LLMTool
import MCP
@testable import LLMMCP

// MARK: - Tool Schema Conversion Tests

/// What a caller listing an MCP server's tools is told about their arguments.
///
/// A real ``MCP/Server`` sits on the other end of an in-memory transport, so these go through
/// the same wire encoding, handshake and pagination as a subprocess server would.
@Suite("SDKClientAdapter Tool Schema")
struct SDKClientAdapterSchemaTests {

    // MARK: - Helpers

    /// Runs `body` against an adapter connected to a server offering `tools`, and shuts both
    /// ends down afterwards whether or not `body` threw.
    private func withServer<Result>(
        offering tools: [MCP.Tool],
        _ body: (SDKClientAdapter) async throws -> Result
    ) async throws -> Result {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = MCP.Server(
            name: "SchemaTestServer",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }
        try await server.start(transport: serverTransport)

        let adapter = SDKClientAdapter(transport: clientTransport)

        do {
            let result = try await body(adapter)
            await adapter.disconnect()
            await server.stop()
            return result
        } catch {
            await adapter.disconnect()
            await server.stop()
            throw error
        }
    }

    /// A schema no `JSONSchema` can be made from: the property is a bare string where an
    /// object belongs. A server really does send this, and the tool really does take a `path`.
    private var unconvertibleSchema: MCP.Value {
        [
            "type": "object",
            "properties": ["path": "string"],
            "required": ["path"],
        ]
    }

    private var convertibleSchema: MCP.Value {
        [
            "type": "object",
            "properties": ["path": ["type": "string", "description": "Where to write"]],
            "required": ["path"],
        ]
    }

    // MARK: - Tests

    @Test("A tool whose schema cannot be converted is not advertised as taking no arguments")
    func unconvertibleSchemaIsNotReportedAsNoArguments() async throws {
        try await withServer(offering: [
            MCP.Tool(
                name: "write_note",
                description: "Write a note to a path",
                inputSchema: unconvertibleSchema
            )
        ]) { adapter in
            do {
                let tools = try await adapter.listTools()
                Issue.record("""
                    Expected the schema conversion failure to surface. \
                    Instead got \(tools.count) tool(s), the first advertising \
                    \(tools.first.map { "\($0.inputSchema)" } ?? "nothing").
                    """)
            } catch {
                // The failure has to say which tool it was, or the caller cannot act on it.
                #expect("\(error)".contains("write_note"))
            }
        }
    }

    @Test("One unconvertible schema does not pass off other tools as argument-free either")
    func unconvertibleSchemaDoesNotSilenceItsNeighbours() async throws {
        try await withServer(offering: [
            MCP.Tool(name: "read_note", description: "Read a note", inputSchema: convertibleSchema),
            MCP.Tool(name: "write_note", description: "Write a note", inputSchema: unconvertibleSchema),
        ]) { adapter in
            do {
                let tools = try await adapter.listTools()
                let argumentFree = tools.filter { $0.inputSchema.properties?.isEmpty ?? true }
                Issue.record("""
                    Expected the schema conversion failure to surface. Instead got \
                    \(tools.count) tool(s), \(argumentFree.count) of them advertising no arguments.
                    """)
            } catch {
                #expect("\(error)".contains("write_note"))
            }
        }
    }

    @Test("A tool with a sound schema keeps its arguments")
    func convertibleSchemaSurvivesTheRoundTrip() async throws {
        try await withServer(offering: [
            MCP.Tool(
                name: "read_note",
                description: "Read a note from a path",
                inputSchema: convertibleSchema
            )
        ]) { adapter in
            let tools = try await adapter.listTools()

            #expect(tools.count == 1)
            let schema = try #require(tools.first?.inputSchema)
            #expect(schema.type == .object)
            #expect(schema.properties?.keys.contains("path") == true)
            #expect(schema.required == ["path"])
        }
    }

    @Test("A tool that genuinely takes no arguments still reports none")
    func genuinelyEmptySchemaIsPreserved() async throws {
        try await withServer(offering: [
            MCP.Tool(
                name: "ping",
                description: "Takes nothing",
                inputSchema: ["type": "object", "properties": [:]]
            )
        ]) { adapter in
            let tools = try await adapter.listTools()

            #expect(tools.count == 1)
            let schema = try #require(tools.first?.inputSchema)
            #expect(schema.type == .object)
            #expect(schema.properties?.isEmpty == true)
        }
    }
}
