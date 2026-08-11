import Foundation
import StructuredDataCore
import JSONParsing
import LLMClient
import LLMTool
import MCP

/// Wraps the MCP SDK client so no SDK type appears in this module's public API.
///
/// One adapter owns one connection. It connects lazily on the first operation and stays
/// connected until ``disconnect()`` — callers that create an adapter per call pay a full
/// connection each time.
internal actor SDKClientAdapter {
    // MARK: - Properties

    private let client: MCP.Client
    private let transport: any Transport
    private var isConnected = false

    // MARK: - Initialization

    #if os(macOS)
    /// Prepares a subprocess-backed adapter. The process starts on first use, not here.
    ///
    /// - Parameters:
    ///   - command: Absolute path to the server executable.
    ///   - arguments: Arguments for it.
    ///   - environment: Variables layered over the parent process environment.
    init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.transport = ProcessTransport(
            command: command,
            arguments: arguments,
            environment: environment
        )
        self.client = MCP.Client(
            name: "swift-llm-agent",
            version: "1.0.0"
        )
    }
    #endif

    /// Prepares an HTTP-backed adapter. No request is sent until first use.
    ///
    /// - Parameters:
    ///   - url: Endpoint of the MCP server.
    ///   - authorization: Applied by a request hook, so it covers every request the transport makes.
    init(url: URL, authorization: MCPAuthorization = .none) {
        switch authorization {
        case .none:
            self.transport = HTTPClientTransport(endpoint: url)
        case .bearer(let token):
            self.transport = HTTPClientTransport(endpoint: url) { request in
                var modifiedRequest = request
                modifiedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return modifiedRequest
            }
        case .header(let name, let value):
            self.transport = HTTPClientTransport(endpoint: url) { request in
                var modifiedRequest = request
                modifiedRequest.setValue(value, forHTTPHeaderField: name)
                return modifiedRequest
            }
        case .headers(let headers):
            self.transport = HTTPClientTransport(endpoint: url) { request in
                var modifiedRequest = request
                for (name, value) in headers {
                    modifiedRequest.setValue(value, forHTTPHeaderField: name)
                }
                return modifiedRequest
            }
        }

        self.client = MCP.Client(
            name: "swift-llm-agent",
            version: "1.0.0"
        )
    }

    // MARK: - Connection Management

    /// Connects and performs the MCP handshake. A second call while connected does nothing.
    func connect() async throws {
        guard !isConnected else { return }
        _ = try await client.connect(transport: transport)
        isConnected = true
    }

    /// Closes the connection and, for stdio, terminates the server process. Safe to call twice.
    func disconnect() async {
        guard isConnected else { return }
        await client.disconnect()
        isConnected = false
    }

    // MARK: - Tool Operations

    /// Lists every tool the server offers, following pagination to the end.
    ///
    /// The loop has no page limit and no cycle detection, so a server that keeps returning
    /// a cursor never terminates.
    func listTools() async throws -> [MCPTool] {
        try await ensureConnected()

        var allTools: [MCP.Tool] = []
        var cursor: String? = nil

        repeat {
            let result = try await client.listTools(cursor: cursor)
            allTools.append(contentsOf: result.tools)
            cursor = result.nextCursor
        } while cursor != nil

        return allTools.map { sdkTool in
            convertToMCPTool(sdkTool)
        }
    }

    /// Calls one tool and flattens the reply into a ``ToolResult``.
    ///
    /// - Parameters:
    ///   - name: Tool name.
    ///   - arguments: A JSON object. Empty data, or JSON that is not an object, is sent as
    ///     no arguments at all rather than rejected.
    /// - Throws: A JSON parse error for malformed input, or a transport or server error.
    func callTool(name: String, arguments: Data) async throws -> ToolResult {
        try await ensureConnected()

        let valueArguments = try convertDataToValueDict(arguments)
        let result = try await client.callTool(name: name, arguments: valueArguments)
        return convertToToolResult(content: result.content, isError: result.isError)
    }

    // MARK: - Private Helpers

    /// Connects if not already connected. Does not reconnect a connection dropped by the peer.
    private func ensureConnected() async throws {
        if !isConnected {
            try await connect()
        }
    }

    /// Converts one SDK tool, binding its call closure back to this adapter.
    ///
    /// The closure holds the adapter weakly, so a tool outlives its adapter only as a value:
    /// calling it after the adapter is released throws "Adapter was deallocated".
    private func convertToMCPTool(_ sdkTool: MCP.Tool) -> MCPTool {
        let inputSchema = convertValueToJSONSchema(sdkTool.inputSchema)

        // Missing hints read as "writable, non-destructive", so an unannotated tool
        // survives the .safe preset and is excluded by .readOnly.
        let capabilities = MCPToolCapabilities.from(
            isReadOnly: sdkTool.annotations.readOnlyHint ?? false,
            isDangerous: sdkTool.annotations.destructiveHint ?? false
        )

        // Capture the name as a value so the closure stays Sendable.
        let toolName = sdkTool.name

        return MCPTool(
            name: sdkTool.name,
            description: sdkTool.description ?? "",
            inputSchema: inputSchema,
            capabilities: capabilities
        ) { [weak self] argumentsData in
            guard let self = self else {
                throw MCPError.toolExecutionFailed(toolName: toolName, underlying: NSError(
                    domain: "LLMMCP",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Adapter was deallocated"]
                ))
            }
            return try await self.callTool(name: toolName, arguments: argumentsData)
        }
    }

    /// Converts an SDK schema `Value` into a ``JSONSchema`` by round-tripping it through structured-data.
    ///
    /// A schema that does not decode becomes an empty object, so the model is told the tool
    /// takes no arguments. The decoding error is discarded, which makes that look like a
    /// tool with no parameters rather than a conversion failure.
    private func convertValueToJSONSchema(_ value: MCP.Value) -> JSONSchema {
        (try? StructuredValue.encoded(value).decode(JSONSchema.self))
            ?? .object(properties: [:], required: [])
    }

    /// Parses argument data into an SDK value dictionary.
    ///
    /// Returns `nil` for empty data and, notably, also for valid JSON that is not an
    /// object — an array or bare scalar is sent as "no arguments" instead of being rejected.
    private func convertDataToValueDict(_ data: Data) throws -> [String: MCP.Value]? {
        guard !data.isEmpty else { return nil }

        guard case .object(let object) = try JSONParser().parse(data) else {
            return nil
        }

        return convertObjectToValueDict(object)
    }

    /// Converts a parsed object to an SDK dictionary, losing key order in the process.
    private func convertObjectToValueDict(_ object: OrderedObject) -> [String: MCP.Value] {
        var result: [String: MCP.Value] = [:]
        for (key, value) in object {
            result[key] = convertValueToMCPValue(value)
        }
        return result
    }

    /// Converts one parsed value to its SDK counterpart, narrowing numbers to `Int` when they fit.
    private func convertValueToMCPValue(_ value: StructuredValue) -> MCP.Value {
        switch value {
        case .null:
            return .null
        case .bool(let bool):
            return .bool(bool)
        case .number(let number):
            if let int = number.int { return .int(int) }
            return .double(number.double)
        case .string(let string):
            return .string(string)
        case .array(let array):
            return .array(array.map { convertValueToMCPValue($0) })
        case .object(let object):
            return .object(convertObjectToValueDict(object))
        }
    }

    /// Flattens a tool reply's content blocks into a single text result, joined by newlines.
    ///
    /// Only text survives intact. Images, audio and binary resources are replaced by a short
    /// placeholder describing them, so a tool that returns a picture returns a caption here.
    private func convertToToolResult(content: [MCP.Tool.Content], isError: Bool?) -> ToolResult {
        var textParts: [String] = []

        for item in content {
            switch item {
            case .text(let text, _, _):
                textParts.append(text)

            case .image(let data, let mimeType, _, _):
                // ToolResult carries text only, so the image is reduced to its first 50
                // base64 characters — enough to identify it, not enough to reconstruct it.
                textParts.append("[Image: \(mimeType), \(data.prefix(50))...]")

            case .audio(let data, let mimeType, _, _):
                // Audio is described rather than carried, for the same reason.
                textParts.append("[Audio: \(mimeType), \(data.count) bytes base64]")

            case .resource(let resource, _, _):
                if let text = resource.text {
                    textParts.append(text)
                } else {
                    textParts.append("[Resource: \(resource.uri), \(resource.mimeType ?? "unknown")]")
                }

            case .resourceLink(let uri, let name, _, _, _, _):
                textParts.append("[ResourceLink: \(name) (\(uri))]")
            }
        }

        // A server-reported failure becomes ToolResult.error, never a thrown error.
        if isError == true {
            return .error(textParts.joined(separator: "\n"))
        }

        return .text(textParts.joined(separator: "\n"))
    }
}
