import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - SerperSearchProvider

/// Searches Google's result pages through the Serper REST API.
///
/// Use it instead of Brave when regional coverage matters: `gl` and `hl` select the Google
/// locale, so Japanese queries return the results a Japanese user would see. Get a key at
/// <https://serper.dev/>.
///
/// ```swift
/// let provider = SerperSearchProvider(apiKey: "YOUR_API_KEY", gl: "jp", hl: "ja")
/// let results = try await provider.search(query: "Swift concurrency", maxResults: 5)
/// ```
public final class SerperSearchProvider: WebSearchProvider, @unchecked Sendable {
    // MARK: - Properties

    private let apiKey: String
    private let gl: String?
    private let hl: String?
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    // MARK: - Initialization

    /// Creates a provider, building a `URLSession`-backed transport unless one is supplied.
    ///
    /// - Parameters:
    ///   - apiKey: Serper API key, sent as `X-API-KEY`. Not validated here.
    ///   - gl: Google region code, such as `"jp"`. Omitted from the request when `nil`.
    ///   - hl: Google interface language, such as `"ja"`. Omitted from the request when `nil`.
    ///   - timeout: Per-request timeout in seconds. The default session also caps the whole
    ///     resource at twice this.
    ///   - transport: Substitute one in tests to avoid real network calls.
    public init(
        apiKey: String,
        gl: String? = nil,
        hl: String? = nil,
        timeout: TimeInterval = 15,
        transport: (any HTTPTransport)? = nil
    ) {
        self.apiKey = apiKey
        self.gl = gl
        self.hl = hl
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

    /// Runs one query against Serper's search endpoint.
    ///
    /// `maxResults` is capped at 100 in the request and the reply is then trimmed to it.
    /// Only the organic results are used — answer boxes, knowledge panels and ads in the
    /// response are discarded, so a query whose answer sits only in a Google answer box
    /// comes back with fewer results than expected.
    ///
    /// - Throws: ``WebSearchError/httpError(statusCode:)`` for any non-2xx status, or a
    ///   decoding error for an unexpected body.
    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        guard let url = URL(string: "https://google.serper.dev/search") else {
            throw WebSearchError.invalidResponse
        }

        let requestBody = SerperSearchRequest(q: query, num: min(maxResults, 100), gl: gl, hl: hl)
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: ["X-API-KEY": apiKey, "Content-Type": "application/json"],
            body: try JSONEncoder().encode(requestBody),
            timeout: timeout
        )

        let response = try await transport.send(request)

        guard (200...299).contains(response.status) else {
            throw WebSearchError.httpError(statusCode: response.status)
        }

        let serperResponse = try JSONDecoder().decode(SerperSearchResponse.self, from: response.body)

        return (serperResponse.organic ?? []).prefix(maxResults).map { result in
            WebSearchResult(
                title: result.title,
                url: result.link,
                snippet: result.snippet ?? ""
            )
        }
    }
}

// MARK: - Serper API Request / Response Types

private struct SerperSearchRequest: Encodable {
    let q: String
    let num: Int
    let gl: String?
    let hl: String?
}

private struct SerperSearchResponse: Decodable {
    let organic: [SerperOrganicResult]?
}

private struct SerperOrganicResult: Decodable {
    let title: String
    let link: String
    let snippet: String?
}
