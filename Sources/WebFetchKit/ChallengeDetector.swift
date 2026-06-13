import Foundation

// MARK: - ChallengeDetector

/// bot チャレンジ / interstitial / JS 必須シェルを検出する。
///
/// これらは HTTP 200 で返るため、検出しないと「成功」として中身（reCAPTCHA の
/// 案内文や "Enable JavaScript" だけ）を LLM に渡してしまう。サイレント失敗を
/// 排除するため、明示的なエラーに昇格させる。
enum ChallengeDetector {

    /// チャレンジ/interstitial ページなら理由文字列を返す。通常ページなら nil。
    ///
    /// 誤検出（チャレンジを「話題にした」正規記事）を避けるため、短い本文に
    /// マーカーが出た場合のみ判定する（チャレンジページは総じて短い）。
    static func detect(title: String?, text: String) -> String? {
        let haystack = ((title ?? "") + "\n" + text).lowercased()

        // タイトル一致は本文長に関係なく強いシグナル
        let titleLower = (title ?? "").lowercased()
        for t in challengeTitles where titleLower.contains(t) {
            return "challenge page (title: \(title ?? ""))"
        }

        // 本文マーカーは短い本文のときのみ（長文記事の誤検出を防ぐ）
        guard text.count < 1500 else { return nil }
        for marker in challengeMarkers where haystack.contains(marker) {
            return "challenge/interstitial marker: \"\(marker)\""
        }
        return nil
    }

    /// チャレンジページに特徴的なタイトル
    private static let challengeTitles: [String] = [
        "just a moment",                       // Cloudflare
        "attention required",                  // Cloudflare
        "ブラウザをチェックしています",            // reCAPTCHA(JP)
        "checking your browser",               // 各種
        "access denied",
        "are you a robot",
        "アクセスできません",
        "security check",
    ]

    /// チャレンジ/JS必須を示す本文マーカー（短い本文のときのみ評価）
    private static let challengeMarkers: [String] = [
        "recaptcha",
        "checking your browser",
        "enable javascript and cookies to continue",
        "please enable javascript",
        "javascript is required",
        "you need to enable javascript",
        "enable javascript to continue",
        "ddos protection by cloudflare",
        "ブラウザをチェックしています",
        "javascriptを有効に",
        "verifying you are human",
        "performance & security by cloudflare",
    ]
}
