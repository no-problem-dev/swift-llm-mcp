import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - BraveSearchProvider

/// Searches with the Brave Search REST API.
///
/// Brave's free tier allows roughly one query per second, which is what the default
/// ``SearchResilienceConfiguration`` is tuned for — call this through
/// ``ResilientSearchProvider`` unless you are pacing requests yourself. Get a key at
/// <https://brave.com/search/api/>.
///
/// ```swift
/// let provider = BraveSearchProvider(apiKey: "YOUR_API_KEY")
/// let results = try await provider.search(query: "Swift concurrency", maxResults: 5)
/// ```
public final class BraveSearchProvider: WebSearchProvider, @unchecked Sendable {
    // MARK: - Properties

    private let apiKey: String
    private let searchLang: String?
    private let country: String?
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    // MARK: - Initialization

    /// Creates a provider, building a `URLSession`-backed transport unless one is supplied.
    ///
    /// - Parameters:
    ///   - apiKey: Brave Search API key, sent as `X-Subscription-Token`. Not validated here.
    ///   - searchLang: Search language, such as `"ja"`. Omitted from the request when `nil`.
    ///   - country: Country code, such as `"JP"`. Omitted from the request when `nil`.
    ///   - timeout: Per-request timeout in seconds. The default session also caps the whole
    ///     resource at twice this.
    ///   - transport: Substitute one in tests to avoid real network calls.
    public init(
        apiKey: String,
        searchLang: String? = nil,
        country: String? = nil,
        timeout: TimeInterval = 15,
        transport: (any HTTPTransport)? = nil
    ) {
        self.apiKey = apiKey
        self.searchLang = searchLang
        self.country = country
        self.timeout = timeout
        if let transport {
            self.transport = transport
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout * 2
            self.transport = URLSessionTransport(session: URLSession(configuration: config), defaultTimeout: timeout)
        }
    }

    // MARK: - WebSearchProvider

    /// Runs one query against Brave's web search endpoint.
    ///
    /// `maxResults` is capped at 20 in the request, Brave's own page limit, and the reply is
    /// then trimmed to `maxResults`. Only web results are used; news, video and other
    /// verticals in the response are discarded.
    ///
    /// - Throws: ``WebSearchError/invalidQuery(_:)`` when the query cannot be put in a URL,
    ///   ``WebSearchError/httpError(statusCode:)`` for any non-2xx status — including the
    ///   429 that a missing rate limit produces — or a decoding error for an unexpected body.
    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(min(maxResults, 20)))
        ]
        if let searchLang {
            queryItems.append(URLQueryItem(name: "search_lang", value: searchLang))
        }
        if let country {
            queryItems.append(URLQueryItem(name: "country", value: country))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw WebSearchError.invalidQuery(query)
        }

        let request = HTTPRequest(
            method: "GET",
            url: url,
            headers: ["X-Subscription-Token": apiKey, "Accept": "application/json"],
            timeout: timeout
        )

        let response = try await transport.send(request)

        guard (200...299).contains(response.status) else {
            throw WebSearchError.httpError(statusCode: response.status)
        }

        let braveResponse = try JSONDecoder().decode(BraveSearchResponse.self, from: response.body)

        return (braveResponse.web?.results ?? []).prefix(maxResults).map { result in
            WebSearchResult(
                title: result.title,
                url: result.url,
                snippet: result.description ?? ""
            )
        }
    }
}

// MARK: - Brave API Response Types

private struct BraveSearchResponse: Decodable {
    let web: BraveWebResults?
}

private struct BraveWebResults: Decodable {
    let results: [BraveWebResult]
}

private struct BraveWebResult: Decodable {
    let title: String
    let url: String
    let description: String?
}
