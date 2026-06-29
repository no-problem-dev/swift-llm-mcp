import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - FetchedDocument

/// fetch の結果（ページネーション前の全文）。
public struct FetchedDocument: Sendable {
    public let url: URL
    public let title: String?
    /// 抽出済み本文（HTML なら Markdown、それ以外は生テキスト）
    public let text: String
    /// maxContentSize 超過で切り詰めたか
    public let wasTruncated: Bool

    public init(url: URL, title: String?, text: String, wasTruncated: Bool) {
        self.url = url
        self.title = title
        self.text = text
        self.wasTruncated = wasTruncated
    }
}

// MARK: - WebFetchHeadersResult

/// `fetchHeaders` の結果。URL・ステータスコード・ヘッダーを保持する。
public struct WebFetchHeadersResult: Sendable {
    public let url: String
    public let statusCode: Int
    public let headers: [String: String]
}

// MARK: - WebFetchEngine

/// URL を取得し、読みやすいテキスト（HTML は Markdown）に変換するコアエンジン。
///
/// MCP / LLMTool には一切依存しない純粋なフェッチ層。`WebToolKit`（MCP アダプタ）
/// や `web-fetch-probe`、その他エージェントから再利用できる。
public struct WebFetchEngine: Sendable {

    /// 許可ドメイン（nil なら全許可）
    public let allowedDomains: Set<String>?
    /// リクエストのタイムアウト秒数
    public let timeout: TimeInterval
    /// 最大取得サイズ（バイト）
    public let maxContentSize: Int
    /// コンテンツ抽出器
    public let extractor: any WebContentExtractor
    /// HTTP トランスポート
    public let transport: any HTTPTransport

    /// WebFetchEngine を作成
    ///
    /// - Parameters:
    ///   - allowedDomains: 許可ドメインの配列（`nil` で全ドメインを許可）
    ///   - timeout: リクエストのタイムアウト秒数（デフォルト: 30）
    ///   - maxContentSize: 最大取得サイズ（バイト、デフォルト: 5 MB）
    ///   - extractor: コンテンツ抽出器（デフォルト: `SwiftSoupContentExtractor`）
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

    // MARK: - Domain Validation

    /// ドメインが許可されているかチェックし、URL を返す。
    public func validateURL(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString) else {
            throw WebFetchError.invalidURL(urlString)
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw WebFetchError.unsupportedScheme(url.scheme ?? "unknown")
        }
        if let allowedDomains,
           let host = url.host?.lowercased(),
           !allowedDomains.contains(host) {
            throw WebFetchError.domainNotAllowed(host, allowed: Array(allowedDomains))
        }
        return url
    }

    // MARK: - fetch

    /// URL を取得し、抽出済み本文（全文）を返す。ページネーションは呼び出し側で行う。
    public func fetch(
        url urlString: String,
        method: String = "GET",
        headers: [String: String]? = nil,
        body: String? = nil,
        raw: Bool = false
    ) async throws -> FetchedDocument {
        let url = try validateURL(urlString)

        // DocC ドキュメント（Apple/Swift）は HTML が JS シェルで本文を持たない。
        // render JSON から全文を取得する。失敗時は通常の HTML 取得にフォールバック。
        if !raw, let jsonURL = DocCSupport.renderJSONURL(for: url),
           let doccDoc = try? await fetchDocC(original: url, jsonURL: jsonURL) {
            return doccDoc
        }

        var requestHeaders: HTTPHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "ja,en;q=0.9",
        ]
        if let headers {
            for (key, value) in headers { requestHeaders[key] = value }
        }

        let request = HTTPRequest(
            method: method,
            url: url,
            headers: requestHeaders,
            body: body?.data(using: .utf8),
            timeout: timeout
        )

        let response = try await transport.send(request)
        let responseData = response.body

        guard (200...299).contains(response.status) else {
            throw WebFetchError.httpError(statusCode: response.status)
        }

        let contentType = response.headers["Content-Type"]

        // バイナリコンテンツ（PDF・画像・音声・動画）はサイズに関わらずテキスト変換不可。
        // 5MB 未満の PDF 等が文字化けテキストとして LLM に流れる害を防ぐ。
        if HTMLDetector.isNonTextBinary(contentType: contentType) {
            throw WebFetchError.binaryContent(contentType: contentType ?? "unknown")
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

        guard let content = EncodingDetector.decode(processData, contentType: contentType) else {
            throw WebFetchError.encodingError
        }

        if !raw {
            // RSS/Atom フィードは item 一覧の Markdown に整形（生 XML の冗長トークン削減）
            if FeedSupport.isFeed(contentType: contentType, content: content),
               let feed = FeedRenderer.render(xml: content) {
                return FetchedDocument(url: url, title: feed.title, text: feed.markdown, wasTruncated: wasTruncated)
            }
            // HTML は本文抽出 + Markdown 化
            if HTMLDetector.isHTML(contentType: contentType, content: content) {
                let extracted = try extractor.extract(html: content, url: url)
                // bot チャレンジ / JS 必須 interstitial を成功扱いせず明示的エラーに昇格
                if let reason = ChallengeDetector.detect(title: extracted.title, text: extracted.content) {
                    throw WebFetchError.challengeBlocked(reason: reason)
                }
                return FetchedDocument(url: url, title: extracted.title, text: extracted.content, wasTruncated: wasTruncated)
            }
        }
        // それ以外（プレーンテキスト/JSON 等）は生テキストを返す
        return FetchedDocument(url: url, title: nil, text: content, wasTruncated: wasTruncated)
    }

    /// DocC render JSON を取得して Markdown 化する。
    private func fetchDocC(original: URL, jsonURL: URL) async throws -> FetchedDocument {
        let request = HTTPRequest(
            method: "GET",
            url: jsonURL,
            headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                "Accept": "application/json",
            ],
            timeout: timeout
        )
        let response = try await transport.send(request)
        guard (200...299).contains(response.status) else {
            throw WebFetchError.httpError(statusCode: response.status)
        }
        guard let rendered = DocCRenderer.render(jsonData: response.body, host: original.host ?? "") else {
            throw WebFetchError.encodingError  // レンダリング失敗 → HTML にフォールバック
        }
        return FetchedDocument(url: original, title: rendered.title, text: rendered.markdown, wasTruncated: false)
    }

    // MARK: - fetch JSON (raw)

    /// JSON 取得用の生レスポンス。パースは呼び出し側に委ねる。
    ///
    /// - Parameters:
    ///   - url: リクエスト URL 文字列
    ///   - method: HTTP メソッド（デフォルト: `"GET"`）
    ///   - headers: カスタムリクエストヘッダー
    ///   - body: リクエストボディ（POST/PUT 用）
    /// - Returns: `(status:, body:, url:)` — ステータスコード・レスポンスボディ・最終 URL
    /// - Throws: ``WebFetchError``
    public func fetchRawJSON(
        url urlString: String,
        method: String = "GET",
        headers: [String: String]? = nil,
        body: String? = nil
    ) async throws -> (status: Int, body: Data, url: URL) {
        let url = try validateURL(urlString)

        var requestHeaders: HTTPHeaders = ["Accept": "application/json"]
        if let headers {
            for (key, value) in headers { requestHeaders[key] = value }
        }
        if body != nil, requestHeaders["Content-Type"] == nil {
            requestHeaders["Content-Type"] = "application/json"
        }

        let request = HTTPRequest(
            method: method,
            url: url,
            headers: requestHeaders,
            body: body?.data(using: .utf8),
            timeout: timeout
        )

        let response = try await transport.send(request)
        guard (200...299).contains(response.status) else {
            throw WebFetchError.httpError(statusCode: response.status)
        }
        guard response.body.count <= maxContentSize else {
            throw WebFetchError.contentTooLarge(size: response.body.count, maxSize: maxContentSize)
        }
        return (response.status, response.body, url)
    }

    // MARK: - fetch headers

    /// HEAD リクエストで HTTP ヘッダーのみを取得
    ///
    /// - Parameter url: リクエスト URL 文字列
    /// - Returns: ステータスコードとヘッダー辞書
    /// - Throws: ``WebFetchError``
    public func fetchHeaders(url urlString: String) async throws -> WebFetchHeadersResult {
        let url = try validateURL(urlString)
        let request = HTTPRequest(method: "HEAD", url: url, timeout: timeout)
        let response = try await transport.send(request)

        var headers: [String: String] = [:]
        for pair in response.headers.pairs {
            headers[pair.name] = pair.value
        }
        return WebFetchHeadersResult(url: url.absoluteString, statusCode: response.status, headers: headers)
    }
}
