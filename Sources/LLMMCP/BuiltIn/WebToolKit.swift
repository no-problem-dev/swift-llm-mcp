import Foundation
import HTTPTransport
import StructuredDataCore
import JSONParsing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMClient
import LLMTool

// MARK: - WebToolKit

/// Web操作ツールを提供するToolKit
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

    /// 許可されたドメイン（nilの場合は全て許可）
    private let allowedDomains: Set<String>?

    /// HTTP トランスポート
    private let transport: any HTTPTransport

    /// タイムアウト秒数
    private let timeout: TimeInterval

    /// 最大コンテンツサイズ（バイト）
    private let maxContentSize: Int

    /// コンテンツ抽出器
    private let extractor: any WebContentExtractor

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
        self.allowedDomains = allowedDomains.map { Set($0.map { $0.lowercased() }) }
        self.timeout = timeout
        self.maxContentSize = maxContentSize
        self.extractor = extractor ?? SwiftSoupContentExtractor()

        if let transport {
            self.transport = transport
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout * 2
            self.transport = URLSessionTransport(session: URLSession(configuration: config), defaultTimeout: timeout)
        }
    }

    // MARK: - ToolKit Protocol

    public var tools: [any Tool] {
        [
            fetchTool,
            fetchJSONTool,
            fetchHeadersTool,
        ]
    }

    // MARK: - Encoding Helper

    /// レスポンスデータを適切なエンコーディングでデコード
    ///
    /// Content-Typeヘッダーからcharsetを解析し、適切なエンコーディングで変換します。
    /// charsetが指定されていない場合や変換に失敗した場合は、フォールバックチェーンを使用します。
    ///
    /// フォールバック順: UTF-8 → ISO-8859-1 → Windows-1252 → Shift_JIS → EUC-JP → ASCII
    private func decodeResponseData(_ data: Data, contentType: String?) -> String? {
        // Content-Typeからcharsetを解析
        if let contentType = contentType,
           let charset = Self.parseCharset(from: contentType),
           let encoding = Self.stringEncoding(from: charset) {
            if let result = String(data: data, encoding: encoding) {
                return result
            }
        }

        // フォールバックチェーン
        let fallbackEncodings: [String.Encoding] = [
            .utf8,
            .isoLatin1,           // ISO-8859-1
            .windowsCP1252,       // Windows-1252
            .shiftJIS,            // Shift_JIS
            .japaneseEUC,         // EUC-JP
            .ascii,
        ]

        for encoding in fallbackEncodings {
            if let result = String(data: data, encoding: encoding) {
                return result
            }
        }

        return nil
    }

    /// Content-Typeヘッダーからcharsetを抽出
    private static func parseCharset(from contentType: String) -> String? {
        // "text/html; charset=UTF-8" → "UTF-8"
        let components = contentType.lowercased().components(separatedBy: ";")
        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("charset=") {
                let charset = trimmed.dropFirst("charset=".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return charset
            }
        }
        return nil
    }

    /// charset名からString.Encodingに変換
    private static func stringEncoding(from charset: String) -> String.Encoding? {
        switch charset.lowercased() {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin1", "iso_8859-1":
            return .isoLatin1
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "shift_jis", "shift-jis", "sjis", "x-sjis":
            return .shiftJIS
        case "euc-jp", "eucjp", "x-euc-jp":
            return .japaneseEUC
        case "ascii", "us-ascii":
            return .ascii
        case "iso-8859-2", "latin2":
            return .isoLatin2
        case "utf-16", "utf16":
            return .utf16
        case "utf-16be":
            return .utf16BigEndian
        case "utf-16le":
            return .utf16LittleEndian
        default:
            // CFStringEncoding経由で追加の変換を試みる
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: nsEncoding)
        }
    }

    // MARK: - Domain Validation

    /// ドメインが許可されているかチェック
    private func validateURL(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString) else {
            throw WebToolKitError.invalidURL(urlString)
        }

        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw WebToolKitError.unsupportedScheme(url.scheme ?? "unknown")
        }

        if let allowedDomains = allowedDomains,
           let host = url.host?.lowercased(),
           !allowedDomains.contains(host) {
            throw WebToolKitError.domainNotAllowed(host, allowed: Array(allowedDomains))
        }

        return url
    }

    // MARK: - HTML Detection

    /// コンテンツがHTMLかどうかを判定
    ///
    /// Content-Typeヘッダーと先頭のHTMLタグの両方で判定します。
    static func isHTMLContent(contentType: String?, content: String) -> Bool {
        // Content-Typeベースの判定
        if let ct = contentType?.lowercased() {
            if ct.contains("text/html") || ct.contains("application/xhtml+xml") {
                return true
            }
        }

        // 先頭タグベースの判定
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html") {
            return true
        }

        return false
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
        ) { [self] data in
            let input = try JSONDecoder().decode(FetchInput.self, from: data)
            let url = try validateURL(input.url)
            let maxLength = input.maxLength ?? 5000
            let startIndex = input.startIndex ?? 0
            let raw = input.raw ?? false

            var requestHeaders: HTTPHeaders = [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "ja,en;q=0.9",
            ]
            if let headers = input.headers {
                for (key, value) in headers {
                    requestHeaders[key] = value
                }
            }

            let request = HTTPRequest(
                method: input.method ?? "GET",
                url: url,
                headers: requestHeaders,
                body: input.body?.data(using: .utf8),
                timeout: timeout
            )

            let response = try await transport.send(request)
            let responseData = response.body

            guard (200...299).contains(response.status) else {
                throw WebToolKitError.httpError(statusCode: response.status)
            }

            let contentType = response.headers["Content-Type"]

            // バイナリコンテンツ（PDF・画像等）はテキスト変換不可のためエラー
            if responseData.count > maxContentSize {
                let ct = contentType?.lowercased() ?? ""
                if ct.contains("application/pdf") || ct.contains("application/octet-stream")
                    || ct.contains("image/") || ct.contains("audio/") || ct.contains("video/") {
                    throw WebToolKitError.contentTooLarge(size: responseData.count, maxSize: maxContentSize)
                }
            }

            // テキスト/HTMLコンテンツは切り詰めて処理続行
            let processData: Data
            let wasTruncated: Bool
            if responseData.count > maxContentSize {
                processData = Data(responseData.prefix(maxContentSize))
                wasTruncated = true
            } else {
                processData = responseData
                wasTruncated = false
            }

            guard let content = decodeResponseData(processData, contentType: contentType) else {
                throw WebToolKitError.encodingError
            }

            // HTML判定 + Markdown抽出
            let title: String?
            let fullText: String

            if !raw && Self.isHTMLContent(contentType: contentType, content: content) {
                let extracted = try extractor.extract(html: content, url: url)
                title = extracted.title
                fullText = extracted.content
            } else {
                title = nil
                fullText = content
            }

            // ページネーション処理
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
                url: url.absoluteString,
                title: title,
                content: paginatedContent,
                contentLength: totalLength,
                startIndex: safeStartIndex,
                hasMore: hasMore,
                nextHint: nil,
                wasTruncated: wasTruncated
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
        ) { [self] data in
            let input = try JSONDecoder().decode(FetchInput.self, from: data)
            let url = try validateURL(input.url)

            var requestHeaders: HTTPHeaders = ["Accept": "application/json"]
            if let headers = input.headers {
                for (key, value) in headers {
                    requestHeaders[key] = value
                }
            }
            if input.body != nil, requestHeaders["Content-Type"] == nil {
                requestHeaders["Content-Type"] = "application/json"
            }

            let request = HTTPRequest(
                method: input.method ?? "GET",
                url: url,
                headers: requestHeaders,
                body: input.body?.data(using: .utf8),
                timeout: timeout
            )

            let response = try await transport.send(request)
            let responseData = response.body

            guard (200...299).contains(response.status) else {
                throw WebToolKitError.httpError(statusCode: response.status)
            }

            guard responseData.count <= maxContentSize else {
                throw WebToolKitError.contentTooLarge(size: responseData.count, maxSize: maxContentSize)
            }

            let parsed = try JSONParser().parse(responseData)
            let result: StructuredValue = .object([
                "url": .string(url.absoluteString),
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
        ) { [self] data in
            let input = try JSONDecoder().decode(FetchHeadersInput.self, from: data)
            let url = try validateURL(input.url)

            let request = HTTPRequest(method: "HEAD", url: url, timeout: timeout)

            let response = try await transport.send(request)

            var headers: [String: String] = [:]
            for pair in response.headers.pairs {
                headers[pair.name] = pair.value
            }

            let result = FetchHeadersResult(
                url: url.absoluteString,
                statusCode: response.status,
                headers: headers
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

// MARK: - Errors

/// WebToolKitのエラー
public enum WebToolKitError: Error, LocalizedError {
    case invalidURL(String)
    case unsupportedScheme(String)
    case domainNotAllowed(String, allowed: [String])
    case invalidResponse
    case httpError(statusCode: Int)
    case contentTooLarge(size: Int, maxSize: Int)
    case encodingError
    case jsonParseError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url). Use web_search to find valid URLs instead of guessing."
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme: \(scheme). Only http and https are supported."
        case .domainNotAllowed(let domain, let allowed):
            return "Domain '\(domain)' is not allowed. Allowed domains: \(allowed.joined(separator: ", ")). Try a different source."
        case .invalidResponse:
            return "Invalid server response. Try a different URL or use web_search to find alternatives."
        case .httpError(let statusCode):
            switch statusCode {
            case 401, 403:
                return "Access blocked (HTTP \(statusCode)). Try a different source."
            case 404:
                return "Page not found (HTTP 404). Use web_search to find valid URLs instead of guessing."
            case 429:
                return "Rate limited (HTTP 429). Wait before retrying, or try a different source."
            case 500...599:
                return "Server error (HTTP \(statusCode)). The server may be temporarily unavailable. Try again later or use a different source."
            default:
                return "HTTP error \(statusCode). Try a different URL or use web_search to find alternatives."
            }
        case .contentTooLarge(let size, let maxSize):
            return "Content too large: \(size) bytes (max: \(maxSize) bytes). This is a binary file (PDF, image, etc.) that cannot be processed as text. Use web_search to find an HTML version or try fetch_headers to check the content type first."
        case .encodingError:
            return "Cannot decode the response encoding. Try a different source."
        case .jsonParseError(let message):
            return "JSON parse error: \(message). Verify the URL returns JSON, or use fetch for non-JSON content."
        }
    }
}
