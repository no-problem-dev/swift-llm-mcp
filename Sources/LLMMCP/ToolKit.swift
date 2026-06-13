import Foundation
import LLMClient
import LLMTool

// MARK: - ToolKit Protocol

/// 関連するツールをグループ化するプロトコル
///
/// ToolKitは複数の関連ツールを束ねて提供します。
/// 公式MCPサーバー（Memory、Filesystem等）と同等の機能を
/// Swift内で直接実装するために使用します。
///
/// ## 使用例
///
/// ```swift
/// let tools = ToolSet {
///     // 外部MCPサーバー
///     MCPServer(command: "npx", arguments: ["-y", "@anthropic/mcp-server-brave"])
///
///     // 内蔵ToolKit
///     FileSystemToolKit(allowedPaths: ["/tmp"])
/// }
/// ```
///
/// ## 実装例
///
/// ```swift
/// public struct MyToolKit: ToolKit {
///     public var name: String { "my-toolkit" }
///
///     public var tools: [any Tool] {
///         [MyTool1(), MyTool2()]
///     }
/// }
/// ```
public protocol ToolKit: Sendable {
    /// ToolKitの識別名
    ///
    /// ログやデバッグ時の識別に使用されます。
    var name: String { get }

    /// このToolKitが提供するツールの配列
    ///
    /// ToolSetに追加される際、この配列のすべてのツールが含まれます。
    var tools: [any Tool] { get }
}

// MARK: - ToolKit Default Extensions

extension ToolKit {
    /// ツール数
    public var toolCount: Int {
        tools.count
    }

    /// ツール名のリスト
    public var toolNames: [String] {
        tools.map { $0.toolName }
    }

    /// 名前でツールを検索
    ///
    /// - Parameter name: ツール名
    /// - Returns: 見つかったツール、またはnil
    public func tool(named name: String) -> (any Tool)? {
        tools.first { $0.toolName == name }
    }
}

// MARK: - BuiltInTool

/// 内蔵ToolKit用のツール
///
/// ToolKitが提供する各ツールの共通機能を提供します。
/// アノテーション情報を保持し、MCPToolCapabilitiesへの変換をサポートします。
public struct BuiltInTool: Tool, Sendable {
    // MARK: - Properties

    public let toolName: String
    public let toolDescription: String
    public let inputSchema: JSONSchema
    public let annotations: ToolAnnotations

    private let executeHandler: @Sendable (Data) async throws -> ToolResult

    // MARK: - Initialization

    /// BuiltInToolを作成
    ///
    /// - Parameters:
    ///   - name: ツール名
    ///   - description: ツールの説明
    ///   - inputSchema: 入力スキーマ
    ///   - annotations: ツールアノテーション
    ///   - handler: 実行ハンドラー
    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        annotations: ToolAnnotations = ToolAnnotations(),
        handler: @escaping @Sendable (Data) async throws -> ToolResult
    ) {
        self.toolName = name
        self.toolDescription = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.executeHandler = handler
    }

    // MARK: - Tool Protocol

    public func execute(with argumentsData: Data) async throws -> ToolResult {
        try await executeHandler(argumentsData)
    }

    // MARK: - Capabilities Conversion

    /// MCPToolCapabilitiesに変換
    ///
    /// MCP仕様に従い、以下のルールで変換します：
    /// - `isReadOnly`: `readOnlyHint`の値（デフォルト: false）
    /// - `isDangerous`: `readOnlyHint`がtrueの場合はfalse、
    ///                  それ以外は`destructiveHint`の値（デフォルト: true）
    public var capabilities: MCPToolCapabilities {
        let isReadOnly = annotations.readOnlyHint ?? false
        let isDangerous = isReadOnly ? false : (annotations.destructiveHint ?? true)
        return MCPToolCapabilities.from(isReadOnly: isReadOnly, isDangerous: isDangerous)
    }
}
