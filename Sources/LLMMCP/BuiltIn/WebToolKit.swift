import Foundation
import HTTPTransport
import StructuredDataCore
import JSONParsing
import LLMClient
import LLMTool
import WebFetchKit

// MARK: - WebToolKit

/// Gives the model three web tools: `fetch`, `fetch_json` and `fetch_headers`.
///
/// A thin MCP adapter over `WebFetchKit.WebFetchEngine`. Its own contribution is
/// pagination: `fetch` returns at most 5000 characters at a time along with a
/// `next_hint` telling the model the `start_index` to ask for next, so a long page arrives
/// over several calls instead of flooding the context window.
///
/// Passing `allowedDomains` is the only access control here — with the default `nil` the
/// model can reach any http or https URL, including private network addresses.
///
/// ```swift
/// let tools = ToolSet {
///     WebToolKit()
/// }
///
/// let restrictedTools = ToolSet {
///     WebToolKit(allowedDomains: ["api.example.com", "data.example.com"])
/// }
///
/// let customTools = ToolSet {
///     WebToolKit(extractor: MyCustomExtractor())
/// }
/// ```
public final class WebToolKit: ToolKit, @unchecked Sendable {
    // MARK: - Properties

    public let name: String = "web"

    private let engine: WebFetchEngine

    // MARK: - Initialization

    /// Creates the kit and the fetch engine behind it.
    ///
    /// - Parameters:
    ///   - allowedDomains: Hosts the model may reach. `nil` allows every host. Matching is
    ///     exact, so subdomains must be listed individually.
    ///   - timeout: Per-request timeout in seconds.
    ///   - maxContentSize: Byte cap on a response body. Applied after the body has been
    ///     received in full, and `fetch` truncates rather than failing.
    ///   - extractor: HTML-to-Markdown extractor. Defaults to `SwiftSoupContentExtractor`.
    ///   - transport: Substitute one in tests to avoid real network calls.
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

    /// The `fetch` tool: retrieve a URL, extract readable text, and hand back one page of it.
    ///
    /// Paginates over characters, not bytes or tokens, defaulting to 5000 characters from
    /// `start_index` 0. `has_more` and `next_hint` tell the model whether to ask again.
    /// A `start_index` past the end is clamped rather than rejected, so it yields an empty
    /// `content` with `has_more: false` instead of an error.
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

            // Slice out the requested window. Indices count Characters, so a page of CJK
            // text yields fewer bytes per call than an ASCII one.
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

    /// The `fetch_json` tool: retrieve a URL and return the parsed JSON.
    ///
    /// Not paginated. An oversized body is rejected rather than truncated, because half a
    /// JSON document cannot be parsed, and a body that is not JSON fails to parse and
    /// reaches the model as a tool error.
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

    /// The `fetch_headers` tool: a HEAD request, so the model can check size or content type
    /// before committing to a full fetch.
    ///
    /// A non-2xx status is reported in the result rather than raised as an error.
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
