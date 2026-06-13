import Foundation
import StructuredDataCore
import JSONParsing
import LLMClient
import LLMTool
import MCP

/// MCP SDKのClientをラップし、自前の型に変換するアダプター
///
/// SDKの詳細をカプセル化し、LLMMCPモジュールの公開APIから
/// SDKの型を隠蔽します。
internal actor SDKClientAdapter {
    // MARK: - Properties

    private let client: MCP.Client
    private let transport: any Transport
    private var isConnected = false

    // MARK: - Initialization

    #if os(macOS)
    /// stdio接続用のアダプターを作成（macOSのみ）
    ///
    /// - Parameters:
    ///   - command: MCPサーバーのコマンドパス
    ///   - arguments: コマンド引数
    ///   - environment: 環境変数
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

    /// HTTP接続用のアダプターを作成
    ///
    /// - Parameters:
    ///   - url: MCPサーバーのURL
    ///   - authorization: 認証設定
    init(url: URL, authorization: MCPAuthorization = .none) {
        // 認証設定に基づいてトランスポートを作成
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

    /// MCPサーバーに接続
    func connect() async throws {
        guard !isConnected else { return }
        _ = try await client.connect(transport: transport)
        isConnected = true
    }

    /// 接続を切断
    func disconnect() async {
        guard isConnected else { return }
        await client.disconnect()
        isConnected = false
    }

    // MARK: - Tool Operations

    /// 利用可能なツール一覧を取得し、MCPTool型に変換
    ///
    /// - Returns: MCPツールの配列
    func listTools() async throws -> [MCPTool] {
        try await ensureConnected()

        var allTools: [MCP.Tool] = []
        var cursor: String? = nil

        // ページネーションを処理
        repeat {
            let result = try await client.listTools(cursor: cursor)
            allTools.append(contentsOf: result.tools)
            cursor = result.nextCursor
        } while cursor != nil

        // SDK型からMCPTool型に変換
        return allTools.map { sdkTool in
            convertToMCPTool(sdkTool)
        }
    }

    /// ツールを実行し、結果をToolResult型に変換
    ///
    /// - Parameters:
    ///   - name: ツール名
    ///   - arguments: 引数（JSON Data）
    /// - Returns: ツール実行結果
    func callTool(name: String, arguments: Data) async throws -> ToolResult {
        try await ensureConnected()

        // DataをMCP.Valueの辞書に変換
        let valueArguments = try convertDataToValueDict(arguments)

        // ツールを実行
        let result = try await client.callTool(name: name, arguments: valueArguments)

        // 結果をToolResultに変換
        return convertToToolResult(content: result.content, isError: result.isError)
    }

    // MARK: - Private Helpers

    /// 接続されていることを確認
    private func ensureConnected() async throws {
        if !isConnected {
            try await connect()
        }
    }

    /// MCP.ToolをMCPToolに変換
    private func convertToMCPTool(_ sdkTool: MCP.Tool) -> MCPTool {
        // inputSchemaを変換
        let inputSchema = convertValueToJSONSchema(sdkTool.inputSchema)

        // annotationsからcapabilitiesを推測
        let capabilities = MCPToolCapabilities.from(
            isReadOnly: sdkTool.annotations.readOnlyHint ?? false,
            isDangerous: sdkTool.annotations.destructiveHint ?? false
        )

        // ツール名をキャプチャ（Sendable対応）
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

    /// MCP SDK の `Value` 形式のスキーマを ``JSONSchema`` へ変換する。
    /// `Value` は Encodable なので structured-data 経由で JSONSchema へ直接デコードする。
    private func convertValueToJSONSchema(_ value: MCP.Value) -> JSONSchema {
        (try? StructuredValue.encoding(value).decode(JSONSchema.self))
            ?? .object(properties: [:], required: [])
    }

    /// DataをMCP.Valueの辞書に変換
    private func convertDataToValueDict(_ data: Data) throws -> [String: MCP.Value]? {
        guard !data.isEmpty else { return nil }

        guard case .object(let object) = try JSONParser().parse(data) else {
            return nil
        }

        return convertObjectToValueDict(object)
    }

    /// OrderedObjectをMCP.Valueの辞書に変換
    private func convertObjectToValueDict(_ object: OrderedObject) -> [String: MCP.Value] {
        var result: [String: MCP.Value] = [:]
        for (key, value) in object {
            result[key] = convertValueToMCPValue(value)
        }
        return result
    }

    /// StructuredValueをMCP.Valueに変換
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

    /// MCP.Tool.ContentをToolResultに変換
    private func convertToToolResult(content: [MCP.Tool.Content], isError: Bool?) -> ToolResult {
        // 複数のコンテンツを結合
        var textParts: [String] = []

        for item in content {
            switch item {
            case .text(let text, _, _):
                textParts.append(text)

            case .image(let data, let mimeType, _, _):
                // 画像はBase64文字列として含める（将来的にToolResultに画像サポートを追加可能）
                textParts.append("[Image: \(mimeType), \(data.prefix(50))...]")

            case .audio(let data, let mimeType, _, _):
                // オーディオはテキストとして表現
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

        // エラーの場合はエラー結果として返す
        if isError == true {
            return .error(textParts.joined(separator: "\n"))
        }

        return .text(textParts.joined(separator: "\n"))
    }
}
