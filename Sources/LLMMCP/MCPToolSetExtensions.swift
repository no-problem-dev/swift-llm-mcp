import Foundation
import LLMClient
import LLMTool

// MARK: - MCPServerWrapper

/// MCPサーバーをToolSetBuilderで使用するためのラッパー
///
/// MCP サーバーは ToolSet に直接追加でき、遅延接続・ツール取得を行う。
/// これにより、宣言的な DSL で MCP サーバーを構成できる。
///
/// ## 使用例
///
/// ```swift
/// let tools = ToolSet {
///     GetWeather()
///     MCPServer(command: "npx", arguments: ["-y", "@anthropic/mcp-server-filesystem", "/path"])
///         .readOnly
/// }
/// ```
public struct MCPServerWrapper: Sendable {
    /// 内部のMCPサーバー
    let server: any MCPServerProtocol

    public init(_ server: any MCPServerProtocol) {
        self.server = server
    }

    /// ツールを取得（必要に応じてMCPサーバーから取得）
    public func getTools() async throws -> [MCPTool] {
        try await server.getFilteredTools()
    }
}

// MARK: - ToolSetBuilder MCP Extensions

extension ToolSetBuilder {
    /// MCPServerProtocol準拠型を配列として構築
    ///
    /// - Parameter server: MCPサーバー
    /// - Returns: ラップされたMCPサーバーの配列
    public static func buildExpression(_ server: some MCPServerProtocol) -> [any Tool] {
        // MCPサーバーは遅延評価が必要なため、プレースホルダーツールを返す
        // 実際のツール取得は runAgent 実行時に行われる
        [MCPServerPlaceholder(server: server)]
    }

    /// MCPServerWrapperを配列として構築
    public static func buildExpression(_ wrapper: MCPServerWrapper) -> [any Tool] {
        [MCPServerPlaceholder(server: wrapper.server)]
    }
}

// MARK: - MCPServerPlaceholder

/// MCPサーバーのプレースホルダーツール
///
/// ToolSet 構築時に使用される一時的なプレースホルダー。
/// 実際の MCP ツールは `resolvingMCPServers()` で取得される。
public final class MCPServerPlaceholder: Tool, @unchecked Sendable {
    /// ラップしているMCPサーバー
    public let server: any MCPServerProtocol

    /// プレースホルダーであることを示すツール名
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

    /// プレースホルダーは直接実行できない
    public func execute(with argumentsData: Data) async throws -> ToolResult {
        throw MCPError.placeholderCannotExecute(serverName: server.serverName)
    }

    /// MCPサーバーから実際のツールを取得
    public func resolveTools() async throws -> [MCPTool] {
        try await server.getFilteredTools()
    }
}

// MARK: - ToolSet MCP Extensions

extension ToolSet {
    /// MCPサーバーのプレースホルダーを実際のツールに解決
    ///
    /// ToolSet に含まれる MCP サーバープレースホルダーを、
    /// 実際の MCP ツールに置き換えた新しい ToolSet を返す。
    ///
    /// - Returns: MCPツールが解決されたToolSet
    /// - Throws: MCP接続エラーまたはツール取得エラー
    public func resolvingMCPServers() async throws -> ToolSet {
        var resolvedTools: [any Tool] = []

        for tool in tools {
            if let placeholder = tool as? MCPServerPlaceholder {
                // MCPサーバーから実際のツールを取得
                let mcpTools = try await placeholder.resolveTools()
                resolvedTools.append(contentsOf: mcpTools)
            } else {
                // 通常のツールはそのまま追加
                resolvedTools.append(tool)
            }
        }

        return ToolSet(tools: resolvedTools)
    }

    /// MCPサーバーのプレースホルダーが含まれているかどうか
    public var containsMCPPlaceholders: Bool {
        tools.contains { $0 is MCPServerPlaceholder }
    }

    /// MCPサーバーのプレースホルダー一覧を取得
    public var mcpPlaceholders: [MCPServerPlaceholder] {
        tools.compactMap { $0 as? MCPServerPlaceholder }
    }
}

// MARK: - MCPError

/// MCPサーバー関連のエラー
public enum MCPError: Error, LocalizedError {
    /// プレースホルダーは直接実行できない
    case placeholderCannotExecute(serverName: String)

    /// サーバー接続エラー
    case connectionFailed(serverName: String, underlying: Error)

    /// ツール取得エラー
    case toolFetchFailed(serverName: String, underlying: Error)

    /// ツール実行エラー
    case toolExecutionFailed(toolName: String, underlying: Error)

    /// ツールが見つからない
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
