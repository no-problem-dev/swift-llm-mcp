import Foundation
import StructuredDataCore
import LLMClient
import LLMTool

// MARK: - MCPTool

/// One tool advertised by an MCP server, presented as an ordinary `Tool`.
///
/// The model sees no difference between this and a locally implemented tool; calling it
/// forwards the arguments to the server that supplied it.
public final class MCPTool: Tool, @unchecked Sendable {
    // MARK: - Properties

    public let toolName: String

    /// The server's own description, which is what the model reads when deciding to call this tool.
    ///
    /// Passed through verbatim, in whatever language the server wrote it.
    public let toolDescription: String

    /// The server's declared argument schema. Falls back to an empty object when the server
    /// sends a schema this package cannot decode.
    public let inputSchema: JSONSchema

    /// What the server claims this tool does, used by ``MCPToolSelection`` presets.
    public let capabilities: MCPToolCapabilities

    private let executeHandler: @Sendable (Data) async throws -> ToolResult

    // MARK: - Initialization

    /// Creates a tool from an already-known definition and a handler that performs the call.
    ///
    /// - Parameters:
    ///   - name: Tool name, as the server reports it.
    ///   - description: Description shown to the model.
    ///   - inputSchema: Argument schema.
    ///   - capabilities: Capability classification. Defaults to ``MCPToolCapabilities/writeSafe``,
    ///     which means an unclassified tool survives the `.safe` preset.
    ///   - executeHandler: Performs the call. It receives the raw JSON argument data.
    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        capabilities: MCPToolCapabilities = .writeSafe,
        executeHandler: @escaping @Sendable (Data) async throws -> ToolResult
    ) {
        self.toolName = name
        self.toolDescription = description
        self.inputSchema = inputSchema
        self.capabilities = capabilities
        self.executeHandler = executeHandler
    }

    // MARK: - Tool Protocol

    /// Forwards the call to the MCP server and returns whatever it reports.
    ///
    /// A tool that fails on the server comes back as a `ToolResult.error`, not as a thrown
    /// error — a throw here means the call never reached the server.
    ///
    /// - Parameter argumentsData: Arguments as a JSON object. Empty data means no arguments.
    public func execute(with argumentsData: Data) async throws -> ToolResult {
        try await executeHandler(argumentsData)
    }
}

// MARK: - MCPTool Creation Helpers

extension MCPTool {
    /// Builds a tool from a raw MCP tool-definition object.
    ///
    /// Because the definition carries no annotations, capabilities are guessed from keywords
    /// in the tool name and description. That guess misfires in both directions —
    /// `forget_memory` reads as read-only because it contains "get" — so prefer the
    /// designated initializer whenever you know the real capabilities.
    ///
    /// - Parameters:
    ///   - json: A tool definition with `name`, `description` and optional `inputSchema`.
    ///   - executeHandler: Performs the call.
    /// - Returns: `nil` when `name` or `description` is missing, which is the only
    ///   signal a caller gets — the underlying decoding error is discarded.
    public static func from(
        json: StructuredValue,
        executeHandler: @escaping @Sendable (Data) async throws -> ToolResult
    ) -> MCPTool? {
        guard let definition = try? json.decode(ToolDefinitionDTO.self),
              let name = definition.name,
              let description = definition.description else {
            return nil
        }

        // A missing schema becomes an empty object, which the model reads as "takes no arguments".
        let inputSchema = definition.inputSchema ?? .object(properties: [:], required: [])

        let capabilities = inferCapabilities(from: name, description: description)

        return MCPTool(
            name: name,
            description: description,
            inputSchema: inputSchema,
            capabilities: capabilities,
            executeHandler: executeHandler
        )
    }

    /// Guesses capabilities from keywords in the tool name and description.
    ///
    /// Substring matching, so it misfires in both directions: `forget_memory` reads as
    /// read-only because it contains "get", and a destructive tool named `purge` is not
    /// caught at all. Only use this when the server sends no annotations.
    private static func inferCapabilities(from name: String, description: String) -> MCPToolCapabilities {
        let lowercaseName = name.lowercased()
        let lowercaseDesc = description.lowercased()

        // Name only: a description mentioning "list" would make every tool look read-only.
        let readOnlyKeywords = ["get", "read", "list", "search", "find", "fetch", "query", "show", "view"]
        let isReadOnly = readOnlyKeywords.contains { lowercaseName.contains($0) || lowercaseName.hasPrefix($0) }

        // Description included here, because it is better to over-report danger than miss it.
        let dangerousKeywords = ["delete", "remove", "drop", "destroy", "force", "admin", "sudo", "root"]
        let isDangerous = dangerousKeywords.contains { lowercaseName.contains($0) || lowercaseDesc.contains($0) }

        return MCPToolCapabilities.from(isReadOnly: isReadOnly, isDangerous: isDangerous)
    }
}

// MARK: - MCP Tool Definition DTO

/// Typed view of an MCP tool-definition object. Every field is optional so a partial
/// definition decodes rather than throwing.
private struct ToolDefinitionDTO: Decodable {
    let name: String?
    let description: String?
    let inputSchema: JSONSchema?
}
