import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMClient
import LLMTool

// MARK: - WebSearchProvider Protocol

/// A search backend, so the search engine can be swapped without touching the tool.
///
/// Conformances compose: ``ResilientSearchProvider`` and ``FallbackSearchProvider`` are
/// themselves providers that wrap other providers.
///
/// ```swift
/// let provider = BraveSearchProvider(apiKey: "YOUR_API_KEY")
/// let results = try await provider.search(query: "Swift concurrency", maxResults: 5)
/// ```
public protocol WebSearchProvider: Sendable {
    /// Runs one search.
    ///
    /// Returning an empty array is not an error at this level, but the wrappers treat it as
    /// one: ``FallbackSearchProvider`` moves on to the next provider when a search comes
    /// back empty.
    ///
    /// - Parameters:
    ///   - query: The query, passed to the backend as given.
    ///   - maxResults: Upper bound on results. A backend may return fewer.
    func search(query: String, maxResults: Int) async throws -> [WebSearchResult]
}

// MARK: - WebSearchResult

/// One hit from a web search.
public struct WebSearchResult: Codable, Sendable {
    public let title: String

    /// The result URL as a string. Not validated, so a malformed one reaches the model unchanged.
    public let url: String

    /// The search engine's excerpt. Empty when the engine supplied none.
    public let snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

// MARK: - UnconfiguredSearchProvider

/// The provider used when no API key was supplied. Every search throws.
///
/// It exists so that leaving search unconfigured is a run-time error with instructions in
/// it, rather than a compile error or a silently empty result list.
public struct UnconfiguredSearchProvider: WebSearchProvider {
    public init() {}

    /// Always throws ``WebSearchError/providerNotConfigured``, whose message names the
    /// factory methods that configure a real backend.
    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        throw WebSearchError.providerNotConfigured
    }
}

// MARK: - WebSearchToolKit

/// Gives the model one tool, `web_search`, backed by Brave or Serper.
///
/// The factory methods wrap the backend in a ``ResilientSearchProvider`` by default, so
/// caching, rate limiting, a circuit breaker and one retry are on unless you pass
/// `resilience: nil`. Constructing the kit directly gives you none of that.
///
/// ```swift
/// let tools = ToolSet {
///     WebSearchToolKit.brave(apiKey: "BRAVE_KEY")
/// }
///
/// // Serper, tuned for Japanese results
/// let tools = ToolSet {
///     WebSearchToolKit.serper(apiKey: "SERPER_KEY", gl: "jp", hl: "ja")
/// }
///
/// // Fall back to a second engine when the first fails or returns nothing
/// let tools = ToolSet {
///     WebSearchToolKit.withFallback(
///         primary: BraveSearchProvider(apiKey: "BRAVE_KEY"),
///         fallback: SerperSearchProvider(apiKey: "SERPER_KEY")
///     )
/// }
/// ```
public final class WebSearchToolKit: ToolKit, @unchecked Sendable {
    // MARK: - Properties

    public let name: String = "web_search"

    private let provider: any WebSearchProvider

    // MARK: - Initialization

    /// Creates a kit around a provider you built yourself, adding no resilience of its own.
    ///
    /// - Parameter provider: The backend. Passing `nil` installs
    ///   ``UnconfiguredSearchProvider``, so the tool exists but every call fails with
    ///   configuration instructions.
    public init(provider: (any WebSearchProvider)? = nil) {
        self.provider = provider ?? UnconfiguredSearchProvider()
    }

    // MARK: - Factory Methods

    /// A kit backed by Brave Search, wrapped in resilience unless you opt out.
    ///
    /// - Parameters:
    ///   - apiKey: Brave Search API key. Not validated here; a bad key surfaces as an
    ///     HTTP error on the first search.
    ///   - searchLang: Search language, such as `"ja"`.
    ///   - country: Country code, such as `"JP"`.
    ///   - resilience: Cache, rate limit, circuit breaker and retry settings.
    ///     Pass `nil` to call Brave directly with none of them.
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

    /// A kit backed by Serper, wrapped in resilience unless you opt out.
    ///
    /// - Parameters:
    ///   - apiKey: Serper API key.
    ///   - gl: Region code, such as `"jp"`.
    ///   - hl: Interface language code, such as `"ja"`.
    ///   - resilience: Cache, rate limit, circuit breaker and retry settings.
    ///     Pass `nil` to call Serper directly with none of them.
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

    /// A kit that tries a second engine when the first fails or returns nothing.
    ///
    /// Each provider gets its own resilience wrapper, so they have separate caches and
    /// separate circuit breakers — the primary tripping does not affect the fallback.
    ///
    /// - Parameters:
    ///   - primary: Tried first.
    ///   - fallback: Tried when the primary throws or returns an empty list.
    ///   - resilience: Applied to each provider individually. Pass `nil` for neither.
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

    /// The `web_search` tool.
    ///
    /// `max_results` is clamped to 1...10 rather than rejected, so an out-of-range value
    /// from the model is quietly corrected. A missing `query` fails decoding and the error
    /// reaches the model as a tool failure.
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

/// Failures from ``WebSearchToolKit`` and the providers behind it.
///
/// Each `errorDescription` tells the model what to do next, because these strings are read
/// by an agent deciding on its next move rather than by a person reading a log.
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
