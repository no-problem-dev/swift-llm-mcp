import Foundation
import HTTPTransport
import StructuredDataCore
import JSONParsing
import LLMClient
import LLMTool
import WebFetchKit

// MARK: - WebToolKit

/// Web操作ツールを提供するToolKit（`WebFetchKit.WebFetchEngine` の MCP アダプタ）
///
/// URLからコンテンツを取得するツールを提供します。
/// HTMLレスポンスは自動でMarkdown形式に変換されます。
///
/// ## 使用例
///
/// ```swift
/// let tools = ToolSet {
///     WebToolKit()
/// }
///
/// // または特定のドメインのみ許可
/// let restrictedTools = ToolSet {
///     WebToolKit(allowedDomains: ["api.example.com", "data.example.com"])
/// }
///
/// // カスタム抽出器を使用
/// let customTools = ToolSet {
///     WebToolKit(extractor: MyCustomExtractor())
/// }
/// ```
///
/// ## 提供されるツール
///
/// - `fetch`: URLからコンテンツを取得（HTML自動Markdown変換、ページネーション対応）
/// - `fetch_json`: URLからJSONを取得してパース
/// - `fetch_headers`: URLからHTTPヘッダーのみを取得
public final class WebToolKit: ToolKit, @unchecked Sendable {
    // MARK: - Properties

    public let name: String = "web"

    /// フェッチエンジン（純粋層）
    private let engine: WebFetchEngine

    // MARK: - Initialization

    /// WebToolKitを作成
    ///
    /// - Parameters:
    ///   - allowedDomains: 許可するドメインの配列（nilの場合は全て許可）
    ///   - timeout: リクエストのタイムアウト秒数（デフォルト: 30）
    ///   - maxContentSize: 最大取得サイズ（デフォルト: 5MB）
    ///   - extractor: コンテンツ抽出器（デフォルト: SwiftSoupContentExtractor）
    ///   - transport: HTTP トランスポート（テスト時に差し替え可能）
    public init(
        allowedDomains: [String]? = nil,
        timeout: TimeInterval = 30,
        maxContentSize: Int = 5 * 1024 * 1024,
        extractor: (any WebContentExtractor)? = nil,
        transport: (any HTTPTransport)? = nil
    ) {
        self.engine = WebFetchEngine(
            allowedDomains: allowedDomains,
            timeout: timeout,
            maxContentSize: maxContentSize,
            extractor: extractor,
            transport: transport
        )
    }

    // MARK: - ToolKit Protocol

    public var tools: [any Tool] {
        [
            fetchTool,
            fetchJSONTool,
            fetchHeadersTool,
        ]
    }

    // MARK: - Tool Definitions

    /// fetch ツール（統合版）
    private var fetchTool: BuiltInTool {
        BuiltInTool(
            name: "fetch",
            description: "Fetch a URL and return its content. For HTML pages, automatically extracts readable content as Markdown. Use `raw: true` to get the original unprocessed content. Supports pagination with start_index/max_length for large content.",
            inputSchema: .object(
                properties: [
                    "url": .string(description: "The URL to fetch content from"),
                    "method": .string(description: "HTTP method (GET, POST, PUT, DELETE). Default: GET"),
                    "headers": .object(
                        description: "Custom HTTP headers to send",
                        properties: [:],
                        required: [],
                        additionalProperties: true
                    ),
                    "body": .string(description: "Request body (for POST/PUT)"),
                    "raw": .boolean(description: "If true, return raw content without Markdown extraction (default: false)"),
                    "max_length": .integer(description: "Maximum characters to return (default: 5000)"),
                    "start_index": .integer(description: "Start position for pagination. Use when previous response indicated more content available (default: 0)"),
                ],
                required: ["url"]
            ),
            annotations: ToolAnnotations(
                title: "Fetch",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { [engine] data in
            let input = try JSONDecoder().decode(FetchInput.self, from: data)
            let maxLength = input.maxLength ?? 5000
            let startIndex = input.startIndex ?? 0

            let doc = try await engine.fetch(
                url: input.url,
                method: input.method ?? "GET",
                headers: input.headers,
                body: input.body,
                raw: input.raw ?? false
            )

            // ページネーション処理
            let fullText = doc.text
            let totalLength = fullText.count
            let safeStartIndex = min(startIndex, max(0, totalLength - 1))
            let endIndex = min(safeStartIndex + maxLength, totalLength)
            let hasMore = endIndex < totalLength

            let paginatedContent: String
            if safeStartIndex < totalLength {
                let start = fullText.index(fullText.startIndex, offsetBy: safeStartIndex)
                let end = fullText.index(fullText.startIndex, offsetBy: endIndex)
                paginatedContent = String(fullText[start..<end])
            } else {
                paginatedContent = ""
            }

            var result = FetchResult(
                url: doc.url.absoluteString,
                title: doc.title,
                content: paginatedContent,
                contentLength: totalLength,
                startIndex: safeStartIndex,
                hasMore: hasMore,
                nextHint: nil,
                wasTruncated: doc.wasTruncated
            )
            if hasMore {
                result.nextHint = "Call fetch with start_index=\(endIndex) to continue reading."
            }

            let output = try JSONEncoder().encode(result)
            return .json(output)
        }
    }

    /// fetch_json ツール
    private var fetchJSONTool: BuiltInTool {
        BuiltInTool(
            name: "fetch_json",
            description: "Fetch JSON from a URL and parse it. Returns the parsed JSON data.",
            inputSchema: .object(
                properties: [
                    "url": .string(description: "The URL to fetch JSON from"),
                    "method": .string(description: "HTTP method (GET, POST, PUT, DELETE). Default: GET"),
                    "headers": .object(
                        description: "Custom HTTP headers to send",
                        properties: [:],
                        required: [],
                        additionalProperties: true
                    ),
                    "body": .string(description: "Request body (for POST/PUT)")
                ],
                required: ["url"]
            ),
            annotations: ToolAnnotations(
                title: "Fetch JSON",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { [engine] data in
            let input = try JSONDecoder().decode(FetchInput.self, from: data)
            let response = try await engine.fetchRawJSON(
                url: input.url,
                method: input.method ?? "GET",
                headers: input.headers,
                body: input.body
            )

            let parsed = try JSONParser().parse(response.body)
            let result: StructuredValue = .object([
                "url": .string(response.url.absoluteString),
                "statusCode": .number(StructuredNumber(integerLiteral: response.status)),
                "data": parsed,
            ])

            let output = try JSONSerializer().serialize(result)
            return .json(output)
        }
    }

    /// fetch_headers ツール
    private var fetchHeadersTool: BuiltInTool {
        BuiltInTool(
            name: "fetch_headers",
            description: "Fetch only HTTP headers from a URL using HEAD request. Useful for checking resource existence or metadata.",
            inputSchema: .object(
                properties: [
                    "url": .string(description: "The URL to fetch headers from")
                ],
                required: ["url"]
            ),
            annotations: ToolAnnotations(
                title: "Fetch Headers",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { [engine] data in
            let input = try JSONDecoder().decode(FetchHeadersInput.self, from: data)
            let headersResult = try await engine.fetchHeaders(url: input.url)
            let result = FetchHeadersResult(
                url: headersResult.url,
                statusCode: headersResult.statusCode,
                headers: headersResult.headers
            )
            let output = try JSONEncoder().encode(result)
            return .json(output)
        }
    }
}

// MARK: - Input Types

private struct FetchInput: Codable {
    var url: String
    var method: String?
    var headers: [String: String]?
    var body: String?
    var raw: Bool?
    var maxLength: Int?
    var startIndex: Int?

    enum CodingKeys: String, CodingKey {
        case url, method, headers, body, raw
        case maxLength = "max_length"
        case startIndex = "start_index"
    }
}

private struct FetchHeadersInput: Codable {
    var url: String
}

// MARK: - Result Types

private struct FetchResult: Codable {
    var url: String
    var title: String?
    var content: String
    var contentLength: Int
    var startIndex: Int
    var hasMore: Bool
    var nextHint: String?
    var wasTruncated: Bool

    enum CodingKeys: String, CodingKey {
        case url, title, content
        case contentLength = "content_length"
        case startIndex = "start_index"
        case hasMore = "has_more"
        case nextHint = "next_hint"
        case wasTruncated = "was_truncated"
    }
}

private struct FetchHeadersResult: Codable {
    var url: String
    var statusCode: Int
    var headers: [String: String]
}
