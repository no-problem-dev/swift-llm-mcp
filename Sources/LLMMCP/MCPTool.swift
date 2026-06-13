import Foundation
import StructuredDataCore
import LLMClient
import LLMTool

// MARK: - MCPTool

/// MCPサーバーから取得したツール
///
/// Toolプロトコルに準拠しており、通常のツールと同様に使用できます。
/// MCPサーバーへの実行リクエストの転送を担当します。
///
/// ## 内部実装詳細
///
/// このクラスはMCPサーバーから取得したツール定義を保持し、
/// `execute(with:)` 呼び出し時にMCPサーバーへリクエストを転送します。
public final class MCPTool: Tool, @unchecked Sendable {
    // MARK: - Properties

    /// ツール名
    public let toolName: String

    /// ツールの説明
    public let toolDescription: String

    /// 入力スキーマ
    public let inputSchema: JSONSchema

    /// ツールの能力フラグ
    public let capabilities: MCPToolCapabilities

    /// 実行ハンドラー
    private let executeHandler: @Sendable (Data) async throws -> ToolResult

    // MARK: - Initialization

    /// MCPToolを作成
    ///
    /// - Parameters:
    ///   - name: ツール名
    ///   - description: ツールの説明
    ///   - inputSchema: 入力スキーマ
    ///   - capabilities: ツールの能力フラグ
    ///   - executeHandler: 実行ハンドラー
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

    /// ツールを実行
    ///
    /// MCPサーバーへリクエストを転送し、結果を返します。
    ///
    /// - Parameter argumentsData: 引数のJSONデータ
    /// - Returns: ツール実行結果
    /// - Throws: 実行エラー
    public func execute(with argumentsData: Data) async throws -> ToolResult {
        try await executeHandler(argumentsData)
    }
}

// MARK: - MCPTool Creation Helpers

extension MCPTool {
    /// JSON定義からMCPToolを作成
    ///
    /// MCPサーバーから返されたツール定義JSONからMCPToolを生成します。
    ///
    /// - Parameters:
    ///   - json: ツール定義JSON
    ///   - executeHandler: 実行ハンドラー
    /// - Returns: MCPTool、またはパース失敗時はnil
    public static func from(
        json: StructuredValue,
        executeHandler: @escaping @Sendable (Data) async throws -> ToolResult
    ) -> MCPTool? {
        guard let definition = try? json.decode(ToolDefinitionDTO.self),
              let name = definition.name,
              let description = definition.description else {
            return nil
        }

        // inputSchema は JSONSchema へ直接デコード（無ければ空オブジェクト）
        let inputSchema = definition.inputSchema ?? .object(properties: [:], required: [])

        // 能力フラグをヒューリスティックに推測
        let capabilities = inferCapabilities(from: name, description: description)

        return MCPTool(
            name: name,
            description: description,
            inputSchema: inputSchema,
            capabilities: capabilities,
            executeHandler: executeHandler
        )
    }

    /// ツール名と説明から能力フラグを推測
    private static func inferCapabilities(from name: String, description: String) -> MCPToolCapabilities {
        let lowercaseName = name.lowercased()
        let lowercaseDesc = description.lowercased()

        // 読み取り専用の判定
        let readOnlyKeywords = ["get", "read", "list", "search", "find", "fetch", "query", "show", "view"]
        let isReadOnly = readOnlyKeywords.contains { lowercaseName.contains($0) || lowercaseName.hasPrefix($0) }

        // 危険な操作の判定
        let dangerousKeywords = ["delete", "remove", "drop", "destroy", "force", "admin", "sudo", "root"]
        let isDangerous = dangerousKeywords.contains { lowercaseName.contains($0) || lowercaseDesc.contains($0) }

        return MCPToolCapabilities.from(isReadOnly: isReadOnly, isDangerous: isDangerous)
    }
}

// MARK: - MCP Tool Definition DTO

/// MCP ツール定義 JSON の型付き表現。`inputSchema` は ``JSONSchema`` へ直接デコードされる。
private struct ToolDefinitionDTO: Decodable {
    let name: String?
    let description: String?
    let inputSchema: JSONSchema?
}
