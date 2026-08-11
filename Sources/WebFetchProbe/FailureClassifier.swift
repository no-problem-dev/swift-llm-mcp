import Foundation
import HTTPTransport
import WebFetchKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - FailureLayer

/// Where in the fetch pipeline a probe ended up.
///
/// The cases follow the order `fetch` does its work — URL validation, network, HTTP, size,
/// encoding, extraction — so a distribution over these values points at the layer to fix.
enum FailureLayer: String, Codable, CaseIterable {
    case ok                       // Content extracted.
    case okThinContent            // 2xx, but the extracted text is very short: likely an SPA or paywall.
    case urlValidation            // 1. Rejected before any request was made.
    case networkTimeout           // 2. Timed out.
    case networkDNS               // 2. Host could not be resolved.
    case networkTLS               // 2. TLS or certificate failure.
    case networkOther             // 2. Any other connection failure.
    case httpClientError          // 3. 4xx, including 401, 403, 404 and 429.
    case httpServerError          // 3. 5xx.
    case challengeBlocked         // 3. A 200 carrying a bot challenge or JavaScript-required page.
    case contentTooLarge          // 4. Binary content type, or over the size cap.
    case encoding                 // 5. No candidate charset decoded the body.
    case extraction               // 6. Parsing the HTML failed.
    case unknown                  // Nothing matched; a gap in the classifier.

    /// True for everything except ``ok``, so ``okThinContent`` counts as a failure here.
    var isFailure: Bool { self != .ok }

    /// Short human-readable name for the report. Currently Japanese.
    var label: String {
        switch self {
        case .ok: return "成功"
        case .okThinContent: return "2xxだが本文薄い(SPA/paywall疑い)"
        case .urlValidation: return "URL検証エラー"
        case .networkTimeout: return "タイムアウト"
        case .networkDNS: return "DNS解決失敗"
        case .networkTLS: return "TLS/証明書エラー"
        case .networkOther: return "ネットワークエラー(その他)"
        case .httpClientError: return "HTTP 4xx"
        case .httpServerError: return "HTTP 5xx"
        case .challengeBlocked: return "bot チャレンジ/JS必須"
        case .contentTooLarge: return "サイズ超過/バイナリ"
        case .encoding: return "エンコーディング不能"
        case .extraction: return "本文抽出失敗"
        case .unknown: return "未分類エラー"
        }
    }
}

// MARK: - Classifier

/// Sorts a thrown error into the pipeline layer that produced it.
enum FailureClassifier {
    /// Extraction shorter than this counts as ``FailureLayer/okThinContent``.
    static let thinContentThreshold = 200

    /// Classifies an error, returning the layer and a detail string for the report.
    ///
    /// Falls back to ``FailureLayer/unknown`` with the error's type name rather than
    /// discarding it, so an unclassified failure is visible in the report as a gap here
    /// rather than as a mystery.
    static func classify(error: Error) -> (layer: FailureLayer, detail: String) {
        // Errors WebFetchEngine raises itself: validation, HTTP, size and encoding.
        if let e = error as? WebFetchError {
            switch e {
            case .invalidURL(let u):
                return (.urlValidation, "invalidURL: \(u)")
            case .unsupportedScheme(let s):
                return (.urlValidation, "unsupportedScheme: \(s)")
            case .domainNotAllowed(let d, _):
                return (.urlValidation, "domainNotAllowed: \(d)")
            case .invalidResponse:
                return (.networkOther, "invalidResponse")
            case .httpError(let code):
                if (500...599).contains(code) {
                    return (.httpServerError, "HTTP \(code)")
                }
                return (.httpClientError, "HTTP \(code)")
            case .contentTooLarge(let size, let max):
                return (.contentTooLarge, "size=\(size) > max=\(max)")
            case .binaryContent(let ct):
                return (.contentTooLarge, "binary content-type: \(ct)")
            case .challengeBlocked(let reason):
                return (.challengeBlocked, reason)
            case .encodingError:
                return (.encoding, "decode failed (charset fallback exhausted)")
            case .jsonParseError(let m):
                return (.extraction, "jsonParseError: \(m)")
            }
        }

        // Network layer. The transport wraps URLError in TransportError.network.
        if let t = error as? TransportError {
            switch t {
            case .network(let underlying):
                return classifyNetwork(underlying)
            case .invalidResponse:
                return (.networkOther, "TransportError.invalidResponse")
            case .cancelled:
                return (.networkOther, "cancelled")
            }
        }

        // Also handle an unwrapped URLError, in case a transport does not wrap it.
        if let urlError = error as? URLError {
            return classifyNetwork(urlError)
        }

        // Extraction failures are matched by type name, because the error type is not public.
        let desc = String(describing: type(of: error))
        if desc.contains("Extractor") || desc.contains("SwiftSoup") {
            return (.extraction, "\(desc): \(error.localizedDescription)")
        }

        return (.unknown, "\(desc): \(error.localizedDescription)")
    }

    /// Splits a `URLError` into timeout, DNS, TLS or other. Anything else becomes
    /// ``FailureLayer/networkOther`` with its numeric code, so unhandled codes stay visible.
    private static func classifyNetwork(_ error: Error) -> (layer: FailureLayer, detail: String) {
        guard let urlError = error as? URLError else {
            return (.networkOther, error.localizedDescription)
        }
        switch urlError.code {
        case .timedOut:
            return (.networkTimeout, "URLError.timedOut")
        case .cannotFindHost, .dnsLookupFailed:
            return (.networkDNS, "URLError.\(urlError.code)")
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return (.networkOther, "URLError.\(urlError.code)")
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return (.networkTLS, "URLError.\(urlError.code)")
        default:
            return (.networkOther, "URLError.\(urlError.code) (\(urlError.code.rawValue))")
        }
    }
}
