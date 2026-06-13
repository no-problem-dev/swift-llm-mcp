import Foundation

// MARK: - WebFetchError

/// WebFetchEngine が投げるエラー。
///
/// （旧 `WebToolKitError`。WebFetchKit 分離に伴いリネーム。）
/// errorDescription は LLM 向けに「次に取るべき行動」を含むメッセージにしている。
public enum WebFetchError: Error, LocalizedError {
    case invalidURL(String)
    case unsupportedScheme(String)
    case domainNotAllowed(String, allowed: [String])
    case invalidResponse
    case httpError(statusCode: Int)
    case contentTooLarge(size: Int, maxSize: Int)
    case binaryContent(contentType: String)
    case challengeBlocked(reason: String)
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
        case .binaryContent(let contentType):
            return "Binary content (\(contentType)) cannot be processed as text. PDFs, images, audio, and video are not supported by fetch. Use web_search to find an HTML version of this resource."
        case .challengeBlocked(let reason):
            return "The page returned a bot-challenge or JavaScript-required interstitial instead of content (\(reason)). The real content could not be retrieved. Try a different source."
        case .encodingError:
            return "Cannot decode the response encoding. Try a different source."
        case .jsonParseError(let message):
            return "JSON parse error: \(message). Verify the URL returns JSON, or use fetch for non-JSON content."
        }
    }
}
