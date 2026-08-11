import Foundation

// MARK: - NoiseSignal

/// A kind of payload that survives extraction and costs the LLM tokens for nothing.
enum NoiseSignal: String, Codable, CaseIterable {
    case base64DataURI      // A huge inline data:...;base64,... blob.
    case duplicateLines     // The same line three or more times: leftover navigation or lists.
    case trackingURL        // Long URLs carrying utm_, gclid, fbclid and friends.
    case blankRuns          // Three or more consecutive newlines.
    case boilerplate        // Cookie notices, subscription prompts, social share text.
    case htmlResidue        // Raw HTML tags, CSS or JavaScript the extractor left behind.
    case linkDense          // Link markup dominates the text: a menu that was not pruned.

    /// Human-readable name for the report. Currently Japanese.
    var label: String {
        switch self {
        case .base64DataURI: return "base64インライン画像"
        case .duplicateLines: return "重複行"
        case .trackingURL: return "トラッキングURL"
        case .blankRuns: return "過剰な空行"
        case .boilerplate: return "定型文(Cookie/購読/SNS)"
        case .htmlResidue: return "HTML/CSS/JS残骸"
        case .linkDense: return "リンク過多(ナビ残骸)"
        }
    }
}

// MARK: - NoiseReport

/// What ``ContentQualityAnalyzer`` found in one page of extracted text.
///
/// The character counts are estimates of waste, not measurements. Signals overlap — a
/// base64 blob inside a duplicated line is counted by both — so ``totalWastedChars`` can
/// exceed the real figure and is only meaningful as a trend across runs.
struct NoiseReport: Codable {
    /// Estimated wasted characters, keyed by ``NoiseSignal`` raw value.
    var wastedCharsBySignal: [String: Int] = [:]
    /// Occurrences, keyed by ``NoiseSignal`` raw value. Counts differ in meaning per signal:
    /// matches for some, distinct offending lines for others.
    var countsBySignal: [String: Int] = [:]
    /// Illustrative snippets for the report, at most one per signal that produces them.
    var samples: [String] = []

    /// Sum of the per-signal estimates, with the double counting described above.
    var totalWastedChars: Int { wastedCharsBySignal.values.reduce(0, +) }

    /// A rough token count: UTF-8 bytes divided by four.
    ///
    /// Not a tokenizer. It over-counts CJK, which takes three bytes per character but
    /// usually fewer than one token, so figures are comparable across runs but not with a
    /// provider's billing.
    static func approxTokens(_ s: String) -> Int { max(0, s.utf8.count / 4) }
}

// MARK: - ContentQualityAnalyzer

/// Scans the extracted Markdown — the exact text an LLM would receive — and quantifies the
/// parts of it that are waste.
///
/// This is what makes extraction changes measurable: run the corpus before and after, and
/// compare wasted characters per signal.
enum ContentQualityAnalyzer {

    /// Runs every signal over one page. Purely textual, with no network access and no state.
    static func analyze(_ content: String) -> NoiseReport {
        var report = NoiseReport()

        analyzeBase64(content, into: &report)
        analyzeDuplicateLines(content, into: &report)
        analyzeTrackingURLs(content, into: &report)
        analyzeBlankRuns(content, into: &report)
        analyzeBoilerplate(content, into: &report)
        analyzeHTMLResidue(content, into: &report)
        analyzeLinkDensity(content, into: &report)

        return report
    }

    // MARK: base64 data URI — historically the single largest source of waste

    /// Counts inline base64 blobs of 100 characters or more. Every matched character is waste.
    private static func analyzeBase64(_ s: String, into r: inout NoiseReport) {
        guard let regex = try? NSRegularExpression(pattern: "data:[^;\\s]+;base64,[A-Za-z0-9+/=]{100,}") else { return }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return }
        let chars = matches.reduce(0) { $0 + $1.range.length }
        r.countsBySignal[NoiseSignal.base64DataURI.rawValue] = matches.count
        r.wastedCharsBySignal[NoiseSignal.base64DataURI.rawValue] = chars
        if let first = matches.first {
            r.samples.append("base64 blob (\(first.range.length)字): " + ns.substring(with: NSRange(location: first.range.location, length: min(60, first.range.length))) + "…")
        }
    }

    // MARK: Duplicate lines

    /// Counts lines that appear three or more times, charging every repeat after the first.
    ///
    /// The count reported is distinct offending lines, not total repetitions.
    private static func analyzeDuplicateLines(_ s: String, into r: inout NoiseReport) {
        let lines = s.components(separatedBy: "\n")
        var counts: [String: Int] = [:]
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count >= 3 else { continue }  // Blank and punctuation-only lines belong to blankRuns.
            counts[t, default: 0] += 1
        }
        var wasted = 0
        var dupKinds = 0
        var sample: String?
        for (line, c) in counts where c >= 3 {
            dupKinds += 1
            wasted += line.count * (c - 1)  // The first occurrence is legitimate; the rest are not.
            if sample == nil { sample = "「\(String(line.prefix(40)))」が\(c)回" }
        }
        guard dupKinds > 0 else { return }
        r.countsBySignal[NoiseSignal.duplicateLines.rawValue] = dupKinds
        r.wastedCharsBySignal[NoiseSignal.duplicateLines.rawValue] = wasted
        if let sample { r.samples.append("重複行: \(sample)") }
    }

    // MARK: Tracking URLs

    /// Counts URLs carrying tracking parameters. The whole URL is charged, not just the
    /// parameters, because a link that should have been stripped is waste in full.
    private static func analyzeTrackingURLs(_ s: String, into r: inout NoiseReport) {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\\)]*(?:utm_|gclid=|fbclid=|mc_eid=|igshid=)[^\\s\\)]*") else { return }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return }
        let chars = matches.reduce(0) { $0 + $1.range.length }
        r.countsBySignal[NoiseSignal.trackingURL.rawValue] = matches.count
        r.wastedCharsBySignal[NoiseSignal.trackingURL.rawValue] = chars
    }

    // MARK: Excess blank lines

    /// Counts runs of three or more newlines, charging everything past the two a paragraph break needs.
    private static func analyzeBlankRuns(_ s: String, into r: inout NoiseReport) {
        guard let regex = try? NSRegularExpression(pattern: "\\n[ \\t]*\\n[ \\t]*(?:\\n[ \\t]*)+") else { return }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return }
        let wasted = matches.reduce(0) { $0 + max(0, $1.range.length - 2) }
        r.countsBySignal[NoiseSignal.blankRuns.rawValue] = matches.count
        r.wastedCharsBySignal[NoiseSignal.blankRuns.rawValue] = wasted
    }

    // MARK: Boilerplate (cookie notices, subscription prompts, social share)

    /// Phrases matched case-insensitively as substrings, in English and Japanese.
    ///
    /// Substring matching means an article discussing privacy policies scores hits too, so
    /// this signal is noisier than the others.
    private static let boilerplatePhrases: [String] = [
        "we use cookies", "accept all cookies", "cookie policy", "manage cookies",
        "subscribe to our newsletter", "sign up for", "create an account", "sign in",
        "follow us on", "share on facebook", "share on twitter", "all rights reserved",
        "terms of service", "privacy policy", "skip to content", "skip to main content",
        "enable javascript", "javascript is disabled",
        "クッキー", "cookieを使用", "を受け入れる", "ニュースレター", "会員登録",
        "ログイン", "新規登録", "利用規約", "プライバシーポリシー", "javascriptを有効",
    ]

    private static func analyzeBoilerplate(_ s: String, into r: inout NoiseReport) {
        let lower = s.lowercased()
        var hits = 0
        var wasted = 0
        var sample: String?
        for phrase in boilerplatePhrases {
            var search = lower.startIndex
            while let range = lower.range(of: phrase, range: search..<lower.endIndex) {
                hits += 1
                wasted += phrase.count
                if sample == nil { sample = phrase }
                search = range.upperBound
            }
        }
        guard hits > 0 else { return }
        r.countsBySignal[NoiseSignal.boilerplate.rawValue] = hits
        r.wastedCharsBySignal[NoiseSignal.boilerplate.rawValue] = wasted
        if let sample { r.samples.append("定型文: 「\(sample)」等 \(hits)箇所") }
    }

    // MARK: HTML / CSS / JavaScript residue

    /// Counts raw markup and script fragments that survived extraction.
    ///
    /// A Markdown code block containing HTML looks identical to leaked markup here, so a
    /// page documenting HTML scores on this signal legitimately.
    private static func analyzeHTMLResidue(_ s: String, into r: inout NoiseReport) {
        var wasted = 0
        var count = 0
        // Raw HTML tags.
        if let tagRegex = try? NSRegularExpression(pattern: "</?(?:div|span|script|style|nav|footer|header|svg|button|input|form|ul|li|a)\\b[^>]*>", options: [.caseInsensitive]) {
            let ns = s as NSString
            let m = tagRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            count += m.count
            wasted += m.reduce(0) { $0 + $1.range.length }
        }
        // CSS and JavaScript fragments.
        for pattern in ["function\\s*\\(", "@media\\b", "\\bvar\\s+\\w+\\s*=", "\\{[^{}]*:[^{}]*;[^{}]*\\}"] {
            if let re = try? NSRegularExpression(pattern: pattern) {
                let ns = s as NSString
                let m = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
                count += m.count
                wasted += m.reduce(0) { $0 + $1.range.length }
            }
        }
        guard count > 0 else { return }
        r.countsBySignal[NoiseSignal.htmlResidue.rawValue] = count
        r.wastedCharsBySignal[NoiseSignal.htmlResidue.rawValue] = wasted
    }

    // MARK: Link density (leftover navigation)

    /// Flags pages where Markdown link markup exceeds 35% of the text, and charges the excess.
    ///
    /// Pages with fewer than 5 links or under 500 characters are skipped: the ratio is
    /// meaningless when the denominator is small.
    private static func analyzeLinkDensity(_ s: String, into r: inout NoiseReport) {
        guard let regex = try? NSRegularExpression(pattern: "\\[[^\\]]*\\]\\([^\\)]*\\)") else { return }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 5, ns.length >= 500 else { return }
        let linkChars = matches.reduce(0) { $0 + $1.range.length }
        let ratio = Double(linkChars) / Double(ns.length)
        guard ratio > 0.35 else { return }
        r.countsBySignal[NoiseSignal.linkDense.rawValue] = matches.count
        r.wastedCharsBySignal[NoiseSignal.linkDense.rawValue] = Int(Double(ns.length) * (ratio - 0.35))
        r.samples.append(String(format: "リンク密度 %.0f%%（%d リンク）", ratio * 100, matches.count))
    }
}
