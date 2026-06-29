import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - SerperSearchProvider

/// Serper (Google SERP) REST APIを使用した検索プロバイダー
///
/// Serper API キーが必要。
/// https://serper.dev/ から取得できる。
///
/// ## 使用例
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

    /// SerperSearchProviderを作成
    ///
    /// - Parameters:
    ///   - apiKey: Serper APIキー
    ///   - gl: 地域コード（例: "jp"）
    ///   - hl: 言語コード（例: "ja"）
    ///   - timeout: リクエストのタイムアウト秒数（デフォルト: 15）
    ///   - transport: HTTP トランスポート（テスト時に差し替え可能）
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
