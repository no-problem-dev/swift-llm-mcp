import Foundation
import HTTPTransport
import WebFetchKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - FailureLayer

/// fetch パイプラインの「どの層で・どう終わったか」を表す分類。
/// WebToolKit.fetch の処理順（URL検証 → ネットワーク → HTTP → サイズ →
/// エンコーディング → 本文抽出）に対応する。
enum FailureLayer: String, Codable, CaseIterable {
    case ok                       // 本文抽出に成功
    case okThinContent            // 2xx だが抽出本文が極端に短い（SPA/paywall 疑い）
    case urlValidation            // ① URL 検証で reject
    case networkTimeout           // ② タイムアウト
    case networkDNS               // ② DNS 解決失敗
    case networkTLS               // ② TLS / 証明書エラー
    case networkOther             // ② その他の接続エラー
    case httpClientError          // ③ 4xx（403/401/404/429 含む）
    case httpServerError          // ③ 5xx
    case challengeBlocked         // ③' bot チャレンジ/JS必須 interstitial
    case contentTooLarge          // ④ バイナリ/サイズ超過
    case encoding                 // ⑤ デコード不能
    case extraction               // ⑥ SwiftSoup 抽出失敗
    case unknown                  // 未分類

    var isFailure: Bool { self != .ok }

    /// 人間向けの短い説明
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

enum FailureClassifier {
    /// 抽出本文がこの文字数未満なら「本文薄い」とみなす閾値。
    static let thinContentThreshold = 200

    /// 投げられたエラーを ``FailureLayer`` に分類する。
    static func classify(error: Error) -> (layer: FailureLayer, detail: String) {
        // ① / ③ / ④ / ⑤: WebFetchEngine 自身のエラー
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

        // ② ネットワーク層: transport は URLError を TransportError.network でラップ
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

        // 念のため URLError が直接来た場合も拾う
        if let urlError = error as? URLError {
            return classifyNetwork(urlError)
        }

        // ⑥ SwiftSoup 抽出失敗など（型は LLMMCP 内 private のため文字列で判定）
        let desc = String(describing: type(of: error))
        if desc.contains("Extractor") || desc.contains("SwiftSoup") {
            return (.extraction, "\(desc): \(error.localizedDescription)")
        }

        return (.unknown, "\(desc): \(error.localizedDescription)")
    }

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
