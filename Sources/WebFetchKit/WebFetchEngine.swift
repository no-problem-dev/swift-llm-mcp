import Foundation
import HTTPTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - FetchedDocument

/// One fetched page, in full — the caller is responsible for paginating it.
public struct FetchedDocument: Sendable {
    /// The URL that was requested, not the final URL after redirects.
    public let url: URL
    public let title: String?
    /// Extracted body: Markdown for HTML and feeds, decoded text for everything else.
    public let text: String
    /// True when the response exceeded `maxContentSize`, so `text` covers only its first bytes.
    public let wasTruncated: Bool

    public init(url: URL, title: String?, text: String, wasTruncated: Bool) {
        self.url = url
        self.title = title
        self.text = text
        self.wasTruncated = wasTruncated
    }
}

// MARK: - WebFetchHeadersResult

/// The outcome of a HEAD request.
public struct WebFetchHeadersResult: Sendable {
    /// The URL that was requested, not the final URL after redirects.
    public let url: String
    public let statusCode: Int
    /// Response headers flattened into a dictionary; a header sent more than once keeps only its last value.
    public let headers: [String: String]
}

// MARK: - WebFetchEngine

/// Fetches a URL and converts the response into text an LLM can read.
///
/// HTML becomes Markdown, RSS/Atom becomes a Markdown item list, and anything else is
/// returned as decoded text. Knows nothing about MCP or tool calling, so the MCP adapter
/// (`WebToolKit`), the `web-fetch-probe` executable and other agents all share one engine.
public struct WebFetchEngine: Sendable {

    /// Hosts this engine may fetch from; `nil` allows every host.
    ///
    /// Matched case-insensitively against the whole host, so subdomains are not implied —
    /// allowing `example.com` still rejects `www.example.com`.
    public let allowedDomains: Set<String>?
    /// Per-request timeout in seconds. The default transport also caps a whole resource at twice this.
    public let timeout: TimeInterval
    /// Byte cap applied to the response body after it has been received in full.
    ///
    /// It bounds what gets decoded, not what gets downloaded or held in memory. `fetch`
    /// truncates at this size; `fetchRawJSON` throws ``WebFetchError/contentTooLarge(size:maxSize:)``.
    public let maxContentSize: Int
    /// Turns HTML into Markdown. Replace it to change what counts as the main content.
    public let extractor: any WebContentExtractor
    /// HTTP layer used by every request. Substitute it in tests to avoid real network calls.
    public let transport: any HTTPTransport

    /// Creates an engine, building a `URLSession`-backed transport unless one is supplied.
    ///
    /// - Parameters:
    ///   - allowedDomains: Hosts to allow; `nil` allows every host. Entries are lowercased.
    ///   - timeout: Per-request timeout in seconds.
    ///   - maxContentSize: Byte cap on the decoded body.
    ///   - extractor: HTML-to-Markdown extractor. Defaults to ``SwiftSoupContentExtractor``.
    ///   - transport: HTTP transport. Supplying one makes `timeout` apply per request only,
    ///     because the resource-level timeout lives on the default session configuration.
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

    /// Parses a URL string and rejects it unless the scheme is http or https and the host is allowed.
    ///
    /// - Throws: ``WebFetchError/invalidURL(_:)``, ``WebFetchError/unsupportedScheme(_:)``
    ///   or ``WebFetchError/domainNotAllowed(_:allowed:)``.
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

    /// Fetches a URL and returns the whole extracted body; the caller paginates it.
    ///
    /// The steps, in order: DocC render-JSON substitution for `developer.apple.com` and
    /// `docs.swift.org`, rejection of any non-2xx status, rejection of binary content types,
    /// truncation to ``maxContentSize``, charset detection, then feed or HTML extraction.
    ///
    /// Two responses that look successful are turned into errors instead. A binary
    /// content type (PDF, image, audio, video) throws rather than reaching the caller as
    /// mojibake, and a page that returns 200 carrying a bot challenge or a
    /// "JavaScript required" interstitial throws ``WebFetchError/challengeBlocked(reason:)``.
    ///
    /// Redirects are left to the transport — this method imposes no redirect limit — and
    /// the returned ``FetchedDocument/url`` is the requested URL, not the final one.
    /// A body over ``maxContentSize`` is truncated rather than rejected, so a caller that
    /// needs completeness must check ``FetchedDocument/wasTruncated``.
    ///
    /// - Parameters:
    ///   - urlString: URL to fetch.
    ///   - method: HTTP method.
    ///   - headers: Extra headers. They overwrite the built-in browser User-Agent, Accept
    ///     and Accept-Language on a key collision.
    ///   - body: Request body, sent as UTF-8. No Content-Type is added for it.
    ///   - raw: Skips DocC, feed and HTML handling and returns the decoded text unchanged.
    ///     Binary rejection and truncation still apply.
    /// - Throws: ``WebFetchError``.
    public func fetch(
        url urlString: String,
        method: String = "GET",
        headers: [String: String]? = nil,
        body: String? = nil,
        raw: Bool = false
    ) async throws -> FetchedDocument {
        let url = try validateURL(urlString)

        // Apple/Swift DocC pages ship an empty JavaScript shell as HTML, so the text has to
        // come from the render JSON. Any failure here falls through to the normal HTML path.
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

        // Binary content cannot become text at any size. Without this, a PDF under the size
        // cap would reach the LLM as mojibake instead of as a failure.
        if HTMLDetector.isNonTextBinary(contentType: contentType) {
            throw WebFetchError.binaryContent(contentType: contentType ?? "unknown")
        }

        // Text and HTML are truncated rather than rejected, so an oversized page still yields
        // its opening section.
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
            // RSS/Atom becomes an item list in Markdown; raw XML wastes tokens.
            if FeedSupport.isFeed(contentType: contentType, content: content),
               let feed = FeedRenderer.render(xml: content) {
                return FetchedDocument(url: url, title: feed.title, text: feed.markdown, wasTruncated: wasTruncated)
            }
            // HTML: pull out the main content and convert it to Markdown.
            if HTMLDetector.isHTML(contentType: contentType, content: content) {
                let extracted = try extractor.extract(html: content, url: url)
                // Promote bot challenges and JavaScript-required interstitials to errors instead
                // of returning them as if they were the page.
                if let reason = ChallengeDetector.detect(title: extracted.title, text: extracted.content) {
                    throw WebFetchError.challengeBlocked(reason: reason)
                }
                return FetchedDocument(url: url, title: extracted.title, text: extracted.content, wasTruncated: wasTruncated)
            }
        }
        // Everything else (plain text, JSON, and any response with raw: true) passes through.
        return FetchedDocument(url: url, title: nil, text: content, wasTruncated: wasTruncated)
    }

    /// Fetches a DocC render JSON document and renders it as Markdown.
    ///
    /// Throws ``WebFetchError/encodingError`` when the JSON is present but cannot be rendered;
    /// the caller treats every error from here as "use the HTML path instead".
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
            throw WebFetchError.encodingError  // Render failure; the caller falls back to HTML.
        }
        return FetchedDocument(url: original, title: rendered.title, text: rendered.markdown, wasTruncated: false)
    }

    // MARK: - fetch JSON (raw)

    /// Fetches a URL and hands back the undecoded bytes, leaving JSON parsing to the caller.
    ///
    /// Unlike ``fetch(url:method:headers:body:raw:)`` this rejects an oversized body instead
    /// of truncating it, because half a JSON document is not parseable.
    ///
    /// - Parameters:
    ///   - urlString: URL to fetch.
    ///   - method: HTTP method.
    ///   - headers: Extra headers. They overwrite the built-in `Accept: application/json`.
    ///   - body: Request body. Supplying one adds `Content-Type: application/json` unless
    ///     `headers` already sets it.
    /// - Returns: The status, the raw body, and the URL that was requested — not the final
    ///   URL after redirects.
    /// - Throws: ``WebFetchError/httpError(statusCode:)`` for any non-2xx status and
    ///   ``WebFetchError/contentTooLarge(size:maxSize:)`` past ``maxContentSize``.
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

    /// Sends a HEAD request to read status and headers without downloading the body.
    ///
    /// Use it to check content type or size before committing to a fetch. A non-2xx status
    /// is reported in the result rather than thrown, so servers that reject HEAD still
    /// return their status here.
    ///
    /// - Parameter urlString: URL to probe.
    /// - Throws: ``WebFetchError`` for an invalid or disallowed URL, or a transport error.
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
