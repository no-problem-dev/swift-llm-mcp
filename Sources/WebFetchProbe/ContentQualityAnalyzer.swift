import Foundation

// MARK: - NoiseSignal

/// 抽出済み本文に含まれる「LLM トークンを浪費する余計なペイロード」の種別。
enum NoiseSignal: String, Codable, CaseIterable {
    case base64DataURI      // data:...;base64,... の巨大インライン blob
    case duplicateLines     // 同一行の3回以上の繰り返し（ナビ/リスト残骸）
    case trackingURL        // utm_ / gclid / fbclid 等トラッキング付き長大 URL
    case blankRuns          // 3連以上の空行
    case boilerplate        // Cookie 同意 / 購読誘導 / SNS シェア等の定型文
    case htmlResidue        // 抽出後に残った生 HTML タグ / CSS / JS
    case linkDense          // テキストに対しリンク markup 比率が高い（メニュー残骸）

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

struct NoiseReport: Codable {
    /// 検出シグナルごとの「無駄と推定される文字数」
    var wastedCharsBySignal: [String: Int] = [:]
    /// 検出シグナルごとの出現件数
    var countsBySignal: [String: Int] = [:]
    /// 代表的な無駄スニペット（最大3件、レポート用）
    var samples: [String] = []

    /// 全体の無駄文字数
    var totalWastedChars: Int { wastedCharsBySignal.values.reduce(0, +) }

    /// 概算トークン（UTF-8 バイト ÷ 4 の粗い近似）
    static func approxTokens(_ s: String) -> Int { max(0, s.utf8.count / 4) }
}

// MARK: - ContentQualityAnalyzer

/// 抽出済み Markdown（= LLM が実際に受け取るテキスト）を走査し、
/// トークンを浪費する余計なペイロードを定量化する。
enum ContentQualityAnalyzer {

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

    // MARK: base64 data URI（最大の浪費要因）

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

    // MARK: 重複行

    private static func analyzeDuplicateLines(_ s: String, into r: inout NoiseReport) {
        let lines = s.components(separatedBy: "\n")
        var counts: [String: Int] = [:]
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count >= 3 else { continue }  // 空行・記号のみは別枠
            counts[t, default: 0] += 1
        }
        var wasted = 0
        var dupKinds = 0
        var sample: String?
        for (line, c) in counts where c >= 3 {
            dupKinds += 1
            wasted += line.count * (c - 1)  // 2回目以降を無駄とみなす
            if sample == nil { sample = "「\(String(line.prefix(40)))」が\(c)回" }
        }
        guard dupKinds > 0 else { return }
        r.countsBySignal[NoiseSignal.duplicateLines.rawValue] = dupKinds
        r.wastedCharsBySignal[NoiseSignal.duplicateLines.rawValue] = wasted
        if let sample { r.samples.append("重複行: \(sample)") }
    }

    // MARK: トラッキング URL

    private static func analyzeTrackingURLs(_ s: String, into r: inout NoiseReport) {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\\)]*(?:utm_|gclid=|fbclid=|mc_eid=|igshid=)[^\\s\\)]*") else { return }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return }
        let chars = matches.reduce(0) { $0 + $1.range.length }
        r.countsBySignal[NoiseSignal.trackingURL.rawValue] = matches.count
        r.wastedCharsBySignal[NoiseSignal.trackingURL.rawValue] = chars
    }

    // MARK: 過剰な空行

    private static func analyzeBlankRuns(_ s: String, into r: inout NoiseReport) {
        guard let regex = try? NSRegularExpression(pattern: "\\n[ \\t]*\\n[ \\t]*(?:\\n[ \\t]*)+") else { return }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return }
        // 3連以上の改行のうち、2つを超える分を無駄とみなす
        let wasted = matches.reduce(0) { $0 + max(0, $1.range.length - 2) }
        r.countsBySignal[NoiseSignal.blankRuns.rawValue] = matches.count
        r.wastedCharsBySignal[NoiseSignal.blankRuns.rawValue] = wasted
    }

    // MARK: 定型文（Cookie / 購読 / SNS シェア）

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

    // MARK: HTML / CSS / JS 残骸

    private static func analyzeHTMLResidue(_ s: String, into r: inout NoiseReport) {
        var wasted = 0
        var count = 0
        // 生 HTML タグ
        if let tagRegex = try? NSRegularExpression(pattern: "</?(?:div|span|script|style|nav|footer|header|svg|button|input|form|ul|li|a)\\b[^>]*>", options: [.caseInsensitive]) {
            let ns = s as NSString
            let m = tagRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            count += m.count
            wasted += m.reduce(0) { $0 + $1.range.length }
        }
        // CSS / JS の断片
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

    // MARK: リンク過多（ナビ残骸）

    private static func analyzeLinkDensity(_ s: String, into r: inout NoiseReport) {
        guard let regex = try? NSRegularExpression(pattern: "\\[[^\\]]*\\]\\([^\\)]*\\)") else { return }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        // 薄ページ（リンク数僅少 / 本文極小）は分母が小さく誤検出するためガード
        guard matches.count >= 5, ns.length >= 500 else { return }
        let linkChars = matches.reduce(0) { $0 + $1.range.length }
        let ratio = Double(linkChars) / Double(ns.length)
        // リンク markup がテキストの 35% 超 = メニュー/リンク集の残骸が支配的
        guard ratio > 0.35 else { return }
        r.countsBySignal[NoiseSignal.linkDense.rawValue] = matches.count
        // 過剰分（35% を超えた分）を無駄とみなす
        r.wastedCharsBySignal[NoiseSignal.linkDense.rawValue] = Int(Double(ns.length) * (ratio - 0.35))
        r.samples.append(String(format: "リンク密度 %.0f%%（%d リンク）", ratio * 100, matches.count))
    }
}
