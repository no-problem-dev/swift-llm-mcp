import Foundation

// MARK: - ChallengeDetector

/// Recognises bot challenges, interstitials and JavaScript-only shells.
///
/// These arrive as HTTP 200, so without this check a reCAPTCHA notice or a bare
/// "Enable JavaScript" line is handed to the LLM as if it were the article. Turning them
/// into an error is what keeps the failure from being silent.
enum ChallengeDetector {

    /// Returns a reason string for a challenge page, or `nil` for an ordinary page.
    ///
    /// A matching title is decisive on its own. Body markers count only when the extracted
    /// text is under 1500 characters, since a real article discussing Cloudflare or
    /// reCAPTCHA would otherwise be rejected — challenge pages are always short.
    static func detect(title: String?, text: String) -> String? {
        let haystack = ((title ?? "") + "\n" + text).lowercased()

        let titleLower = (title ?? "").lowercased()
        for t in challengeTitles where titleLower.contains(t) {
            return "challenge page (title: \(title ?? ""))"
        }

        guard text.count < 1500 else { return nil }
        for marker in challengeMarkers where haystack.contains(marker) {
            return "challenge/interstitial marker: \"\(marker)\""
        }
        return nil
    }

    /// Titles that only challenge pages use. A substring match on any of these is conclusive.
    private static let challengeTitles: [String] = [
        "just a moment",                       // Cloudflare
        "attention required",                  // Cloudflare
        "ブラウザをチェックしています",            // reCAPTCHA (Japanese)
        "checking your browser",               // several vendors
        "access denied",
        "are you a robot",
        "アクセスできません",
        "security check",
    ]

    /// Body phrases that indicate a challenge or a JavaScript requirement.
    ///
    /// Checked against title and body together, and only for short text.
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
