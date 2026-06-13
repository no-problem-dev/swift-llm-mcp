import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMClient
import LLMTool

// MARK: - WebSearchProvider Protocol

/// Web検索プロバイダーのプロトコル
///
/// 異なる検索エンジンバックエンドを差し替え可能にするための抽象化です。
///
/// ## 使用例
///
/// ```swift
/// let provider = BraveSearchProvider(apiKey: "YOUR_API_KEY")
/// let results = try await provider.search(query: "Swift concurrency", maxResults: 5)
/// ```
public protocol WebSearchProvider: Sendable {
    /// 検索を実行
    ///
    /// - Parameters:
    ///   - query: 検索クエリ
    ///   - maxResults: 最大結果数
    /// - Returns: 検索結果の配列
    func search(query: String, maxResults: Int) async throws -> [WebSearchResult]
}

// MARK: - WebSearchResult

/// Web検索の結果
public struct WebSearchResult: Codable, Sendable {
    /// ページタイトル
    public let title: String

    /// ページURL
    public let url: String

    /// 検索結果のスニペット
    public let snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

// MARK: - UnconfiguredSearchProvider

/// APIキー未設定時のフォールバックプロバイダー
///
/// 検索実行時に設定方法を案内するエラーを返します。
/// ビルドは通るが、実行時にユーザーに設定を促します。
public struct UnconfiguredSearchProvider: WebSearchProvider {
    public init() {}

    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        throw WebSearchError.providerNotConfigured
    }
}

// MARK: - WebSearchToolKit

/// Web検索ツールを提供するToolKit
///
/// Web検索を実行し、タイトル・URL・スニペットの一覧を返します。
/// Brave Search API または Serper API をバックエンドとして使用します。
///
/// ## 使用例
///
/// ```swift
/// // Brave Search API
/// let tools = ToolSet {
///     WebSearchToolKit.brave(apiKey: "BRAVE_KEY")
/// }
///
/// // Serper API（日本語最適化）
/// let tools = ToolSet {
///     WebSearchToolKit.serper(apiKey: "SERPER_KEY", gl: "jp", hl: "ja")
/// }
///
/// // フォールバックチェーン
/// let tools = ToolSet {
///     WebSearchToolKit.withFallback(
///         primary: BraveSearchProvider(apiKey: "BRAVE_KEY"),
///         fallback: SerperSearchProvider(apiKey: "SERPER_KEY")
///     )
/// }
/// ```
///
/// ## 提供されるツール
///
/// - `web_search`: クエリでWeb検索を実行し、結果一覧を返す
public final class WebSearchToolKit: ToolKit, @unchecked Sendable {
    // MARK: - Properties

    public let name: String = "web_search"

    /// 検索プロバイダー
    private let provider: any WebSearchProvider

    // MARK: - Initialization

    /// WebSearchToolKitを作成
    ///
    /// - Parameter provider: 検索プロバイダー（デフォルト: UnconfiguredSearchProvider）
    public init(provider: (any WebSearchProvider)? = nil) {
        self.provider = provider ?? UnconfiguredSearchProvider()
    }

    // MARK: - Factory Methods

    /// Brave Search APIプロバイダーでWebSearchToolKitを作成
    ///
    /// - Parameters:
    ///   - apiKey: Brave Search APIキー
    ///   - searchLang: 検索言語（例: "ja"）
    ///   - country: 国コード（例: "JP"）
    ///   - resilience: レジリエンス設定（nil でレジリエンスなし）
    /// - Returns: 設定済みのWebSearchToolKit
    public static func brave(
        apiKey: String,
        searchLang: String? = nil,
        country: String? = nil,
        resilience: SearchResilienceConfiguration? = .default
    ) -> WebSearchToolKit {
        let base = BraveSearchProvider(apiKey: apiKey, searchLang: searchLang, country: country)
        if let resilience {
            return WebSearchToolKit(provider: ResilientSearchProvider(provider: base, configuration: resilience))
        }
        return WebSearchToolKit(provider: base)
    }

    /// Serper APIプロバイダーでWebSearchToolKitを作成
    ///
    /// - Parameters:
    ///   - apiKey: Serper APIキー
    ///   - gl: 地域コード（例: "jp"）
    ///   - hl: 言語コード（例: "ja"）
    ///   - resilience: レジリエンス設定（nil でレジリエンスなし）
    /// - Returns: 設定済みのWebSearchToolKit
    public static func serper(
        apiKey: String,
        gl: String? = nil,
        hl: String? = nil,
        resilience: SearchResilienceConfiguration? = .default
    ) -> WebSearchToolKit {
        let base = SerperSearchProvider(apiKey: apiKey, gl: gl, hl: hl)
        if let resilience {
            return WebSearchToolKit(provider: ResilientSearchProvider(provider: base, configuration: resilience))
        }
        return WebSearchToolKit(provider: base)
    }

    /// フォールバックチェーン付きWebSearchToolKitを作成
    ///
    /// - Parameters:
    ///   - primary: プライマリプロバイダー
    ///   - fallback: フォールバックプロバイダー
    ///   - resilience: 各プロバイダーに適用するレジリエンス設定（nil でレジリエンスなし）
    /// - Returns: 設定済みのWebSearchToolKit
    public static func withFallback(
        primary: any WebSearchProvider,
        fallback: any WebSearchProvider,
        resilience: SearchResilienceConfiguration? = .default
    ) -> WebSearchToolKit {
        let wrappedPrimary: any WebSearchProvider
        let wrappedFallback: any WebSearchProvider
        if let resilience {
            wrappedPrimary = ResilientSearchProvider(provider: primary, configuration: resilience)
            wrappedFallback = ResilientSearchProvider(provider: fallback, configuration: resilience)
        } else {
            wrappedPrimary = primary
            wrappedFallback = fallback
        }
        return WebSearchToolKit(provider: FallbackSearchProvider(providers: [wrappedPrimary, wrappedFallback]))
    }

    // MARK: - ToolKit Protocol

    public var tools: [any Tool] {
        [
            webSearchTool
        ]
    }

    // MARK: - Tool Definitions

    /// web_search ツール
    private var webSearchTool: BuiltInTool {
        BuiltInTool(
            name: "web_search",
            description: "Search the web and return a list of results with titles, URLs, and snippets. Use this to find information, discover URLs, or research topics.",
            inputSchema: .object(
                properties: [
                    "query": .string(description: "The search query"),
                    "max_results": .integer(description: "Maximum number of results to return (1-10, default: 5)")
                ],
                required: ["query"]
            ),
            annotations: ToolAnnotations(
                title: "Web Search",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(WebSearchInput.self, from: data)

            let maxResults = min(max(input.maxResults ?? 5, 1), 10)

            let results = try await provider.search(query: input.query, maxResults: maxResults)

            let output = WebSearchOutput(
                query: input.query,
                resultCount: results.count,
                results: results
            )

            let encoded = try JSONEncoder().encode(output)
            return .json(encoded)
        }
    }
}

// MARK: - Input / Output Types

private struct WebSearchInput: Codable {
    var query: String
    var maxResults: Int?

    enum CodingKeys: String, CodingKey {
        case query
        case maxResults = "max_results"
    }
}

private struct WebSearchOutput: Codable {
    var query: String
    var resultCount: Int
    var results: [WebSearchResult]

    enum CodingKeys: String, CodingKey {
        case query
        case resultCount = "result_count"
        case results
    }
}

// MARK: - Errors

/// WebSearchToolKitのエラー
public enum WebSearchError: Error, LocalizedError {
    case invalidQuery(String)
    case invalidResponse
    case httpError(statusCode: Int)
    case encodingError
    case noResults
    case providerNotConfigured
    case circuitBreakerOpen
    case allProvidersFailed([Error])

    public var errorDescription: String? {
        switch self {
        case .invalidQuery(let query):
            return "Invalid search query: \(query). Try rephrasing your query."
        case .invalidResponse:
            return "Search engine returned an invalid response. Try again or rephrase your query."
        case .httpError(let statusCode):
            switch statusCode {
            case 429:
                return "Search rate limited (HTTP 429). Wait before retrying."
            case 403:
                return "Search access blocked (HTTP 403). Try again later."
            default:
                return "Search failed with HTTP \(statusCode). Try again or rephrase your query."
            }
        case .encodingError:
            return "Cannot decode the search results. Try again."
        case .noResults:
            return "No results found. Try different keywords or a broader query."
        case .providerNotConfigured:
            return "No search provider configured. Use WebSearchToolKit.brave(apiKey:) or WebSearchToolKit.serper(apiKey:) to configure a search provider."
        case .circuitBreakerOpen:
            return "Search provider is temporarily unavailable due to repeated failures. Try again later."
        case .allProvidersFailed(let errors):
            let descriptions = errors.map { $0.localizedDescription }.joined(separator: "; ")
            return "All search providers failed: \(descriptions)"
        }
    }
}
