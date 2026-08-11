import Foundation
import LLMClient
import LLMTool

// MARK: - MCPServerWrapper

/// Wraps a server so a `ToolSet` builder accepts it where a `Tool` is expected.
///
/// Needed only when the static type is `any MCPServerProtocol`; a concrete ``MCPServer``
/// goes into the builder directly.
///
/// ```swift
/// let tools = ToolSet {
///     GetWeather()
///     MCPServer(command: "npx", arguments: ["-y", "@anthropic/mcp-server-filesystem", "/path"])
///         .readOnly
/// }
/// ```
public struct MCPServerWrapper: Sendable {
    let server: any MCPServerProtocol

    public init(_ server: any MCPServerProtocol) {
        self.server = server
    }

    /// Connects and returns the filtered tools. Nothing is cached, so each call reconnects.
    public func getTools() async throws -> [MCPTool] {
        try await server.getFilteredTools()
    }
}

// MARK: - ToolSetBuilder MCP Extensions

extension ToolSetBuilder {
    /// Accepts a server in a `ToolSet` builder, deferring the connection.
    ///
    /// Building a `ToolSet` is synchronous but listing a server's tools is not, so the
    /// server becomes a single ``MCPServerPlaceholder`` here. Call
    /// `ToolSet.resolvingMCPServers()` before running an agent, or the model is offered
    /// the placeholder instead of the real tools.
    public static func buildExpression(_ server: some MCPServerProtocol) -> [any Tool] {
        [MCPServerPlaceholder(server: server)]
    }

    /// Accepts a wrapped server in a `ToolSet` builder, deferring the connection the same way.
    public static func buildExpression(_ wrapper: MCPServerWrapper) -> [any Tool] {
        [MCPServerPlaceholder(server: wrapper.server)]
    }
}

// MARK: - MCPServerPlaceholder

/// Stands in for a server's tools until `ToolSet.resolvingMCPServers()` replaces it.
///
/// It conforms to `Tool` only so it can sit in a `ToolSet`; calling it always throws.
/// Seeing `__mcp_placeholder_*` in a model's tool list means resolution was skipped.
public final class MCPServerPlaceholder: Tool, @unchecked Sendable {
    public let server: any MCPServerProtocol

    /// A reserved name, prefixed `__mcp_placeholder_`, that no real tool should collide with.
    public var toolName: String {
        "__mcp_placeholder_\(server.serverName)"
    }

    public var toolDescription: String {
        "MCP Server placeholder for \(server.serverName)"
    }

    public var inputSchema: JSONSchema {
        .object(description: nil, properties: [:], required: [])
    }

    public init(server: any MCPServerProtocol) {
        self.server = server
    }

    /// Always throws ``MCPError/placeholderCannotExecute(serverName:)``.
    public func execute(with argumentsData: Data) async throws -> ToolResult {
        throw MCPError.placeholderCannotExecute(serverName: server.serverName)
    }

    /// Connects to the server and returns the tools this placeholder stands for.
    public func resolveTools() async throws -> [MCPTool] {
        try await server.getFilteredTools()
    }
}

// MARK: - ToolSet MCP Extensions

extension ToolSet {
    /// Connects to every MCP server in this set and returns a set with real tools in place
    /// of the placeholders.
    ///
    /// Call it once before handing the set to a model. Servers are contacted one after
    /// another, in tool order, and the first failure aborts the whole thing — one
    /// unreachable server means no resolved `ToolSet` at all.
    ///
    /// - Throws: Whatever a server's transport reports while connecting or listing.
    public func resolvingMCPServers() async throws -> ToolSet {
        var resolvedTools: [any Tool] = []

        for tool in tools {
            if let placeholder = tool as? MCPServerPlaceholder {
                let mcpTools = try await placeholder.resolveTools()
                resolvedTools.append(contentsOf: mcpTools)
            } else {
                resolvedTools.append(tool)
            }
        }

        return ToolSet(tools: resolvedTools)
    }

    /// Whether this set still needs ``resolvingMCPServers()``.
    public var containsMCPPlaceholders: Bool {
        tools.contains { $0 is MCPServerPlaceholder }
    }

    /// The unresolved servers in this set, one entry per server.
    public var mcpPlaceholders: [MCPServerPlaceholder] {
        tools.compactMap { $0 as? MCPServerPlaceholder }
    }
}

// MARK: - MCPError

/// Failures raised by this package rather than by an MCP server itself.
///
/// Errors the server reports about a tool call arrive as `ToolResult.error`, not here.
public enum MCPError: Error, LocalizedError {
    /// A placeholder was called directly, which means `ToolSet.resolvingMCPServers()` was never run.
    case placeholderCannotExecute(serverName: String)

    case connectionFailed(serverName: String, underlying: Error)

    case toolFetchFailed(serverName: String, underlying: Error)

    case toolExecutionFailed(toolName: String, underlying: Error)

    case toolNotFound(toolName: String, serverName: String)

    public var errorDescription: String? {
        switch self {
        case .placeholderCannotExecute(let name):
            return "MCP server '\(name)' placeholder cannot be executed directly. Call resolvingMCPServers() first."
        case .connectionFailed(let name, let error):
            return "Failed to connect to MCP server '\(name)': \(error.localizedDescription)"
        case .toolFetchFailed(let name, let error):
            return "Failed to fetch tools from MCP server '\(name)': \(error.localizedDescription)"
        case .toolExecutionFailed(let name, let error):
            return "Failed to execute MCP tool '\(name)': \(error.localizedDescription)"
        case .toolNotFound(let tool, let server):
            return "Tool '\(tool)' not found in MCP server '\(server)'"
        }
    }
}
