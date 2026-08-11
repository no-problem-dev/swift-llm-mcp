import Foundation

// MARK: - ReportDiff
//
// Compares two probe reports so a change to the fetcher or extractor can be judged rather
// than guessed at. This is the regression gate.
//
//   Improvement: failure -> success, thin -> ok, less wasted content.
//   Regression:  success -> failure, ok -> thin, content shrinking sharply
//                (over-aggressive sanitising), more waste.
//
// Matched by URL, so entries added to or removed from the corpus are reported separately
// rather than silently ignored.

/// Compares two probe report JSON files and renders the difference as Markdown.
enum ReportDiff {

    /// Ranks an outcome so two runs can be compared: 2 for extracted content, 1 for thin
    /// content, 0 for any failure.
    ///
    /// Deliberately coarse — a 404 and a timeout both rank 0, because the point is whether
    /// a URL got better or worse, not how it failed.
    static func qualityRank(_ layer: FailureLayer) -> Int {
        switch layer {
        case .ok: return 2
        case .okThinContent: return 1
        default: return 0
        }
    }

    /// Fraction a page's content must shrink by before it counts as lost content.
    ///
    /// Both this and ``shrinkAbsThreshold`` must be exceeded, so trimming boilerplate off a
    /// short page does not register while gutting a long article does.
    static let shrinkRatioThreshold = 0.25
    /// Characters a page's content must shrink by, alongside ``shrinkRatioThreshold``.
    static let shrinkAbsThreshold = 1000

    /// How one URL changed between the two runs.
    struct PairDelta {
        let url: String
        let category: ProbeCategory
        let before: ProbeResult
        let after: ProbeResult

        var rankDelta: Int { qualityRank(after.layer) - qualityRank(before.layer) }
        var contentDelta: Int { after.contentLength - before.contentLength }
        var wastedBefore: Int { before.noise?.totalWastedChars ?? 0 }
        var wastedAfter: Int { after.noise?.totalWastedChars ?? 0 }
        var wastedDelta: Int { wastedAfter - wastedBefore }

        /// The outcome got worse: content became thin, or a working page stopped working.
        var isLayerRegression: Bool { rankDelta < 0 }
        /// Both runs succeeded but the content shrank sharply, suggesting over-aggressive removal.
        var isContentShrink: Bool {
            guard qualityRank(before.layer) >= 1, qualityRank(after.layer) >= 1 else { return false }
            guard before.contentLength > 0 else { return false }
            let ratio = Double(before.contentLength - after.contentLength) / Double(before.contentLength)
            return ratio > shrinkRatioThreshold && (before.contentLength - after.contentLength) > shrinkAbsThreshold
        }
        /// More waste counts as a regression only when the outcome did not improve.
        ///
        /// A page that went from failing to succeeding gained waste because it gained
        /// content, which is not a regression.
        var isWastedRegression: Bool { wastedDelta > 50 && rankDelta <= 0 }
        /// True if any of the three regression tests fires.
        var isRegression: Bool { isLayerRegression || isContentShrink || isWastedRegression }
        /// True if the outcome improved or waste dropped by more than 50 characters.
        ///
        /// Not the negation of ``isRegression``: a page can be both, by improving its layer
        /// while shrinking sharply.
        var isImprovement: Bool { rankDelta > 0 || wastedDelta < -50 }
    }

    /// Decodes a probe report JSON file.
    ///
    /// - Throws: A file-system or decoding error. A report written by an older version with
    ///   a different ``ProbeResult`` shape fails here rather than diffing partially.
    static func loadResults(_ path: String) throws -> [ProbeResult] {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ProbeResult].self, from: data)
    }

    /// Compares two report files and renders the difference as Markdown.
    ///
    /// URLs appearing twice in one report keep their first occurrence. Output is Japanese,
    /// and this returns a document rather than an exit status — reading it is a human step.
    static func diffMarkdown(beforePath: String, afterPath: String) throws -> String {
        let before = try loadResults(beforePath)
        let after = try loadResults(afterPath)
        let beforeByURL = Dictionary(before.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let afterByURL = Dictionary(after.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })

        var pairs: [PairDelta] = []
        for (url, b) in beforeByURL {
            if let a = afterByURL[url] {
                pairs.append(PairDelta(url: url, category: b.category, before: b, after: a))
            }
        }
        let removed = beforeByURL.keys.filter { afterByURL[$0] == nil }.sorted()
        let added = afterByURL.keys.filter { beforeByURL[$0] == nil }.sorted()

        var out = "# Web Fetch Probe — Before/After Diff\n\n"
        out += "- before: `\(beforePath)` (\(before.count) URL)\n"
        out += "- after:  `\(afterPath)` (\(after.count) URL)\n"
        out += "- 共通比較対象: \(pairs.count) URL\n\n"

        // Aggregate counts, so the headline numbers come before the per-URL detail.
        out += "## 集計デルタ\n\n"
        out += "| 指標 | before | after | Δ |\n|---|---:|---:|---:|\n"
        out += aggRow("ok", before.filter { $0.layer == .ok }.count, after.filter { $0.layer == .ok }.count)
        out += aggRow("thin", before.filter { $0.layer == .okThinContent }.count, after.filter { $0.layer == .okThinContent }.count)
        out += aggRow("失敗", before.filter { $0.layer.isFailure && $0.layer != .okThinContent }.count, after.filter { $0.layer.isFailure && $0.layer != .okThinContent }.count)
        let wBefore = before.reduce(0) { $0 + ($1.noise?.totalWastedChars ?? 0) }
        let wAfter = after.reduce(0) { $0 + ($1.noise?.totalWastedChars ?? 0) }
        out += aggRow("無駄文字(合計)", wBefore, wAfter)
        out += aggRow("無駄≈トークン", wBefore / 4, wAfter / 4)
        let tBefore = before.reduce(0) { $0 + $1.approxTokens }
        let tAfter = after.reduce(0) { $0 + $1.approxTokens }
        out += aggRow("総≈トークン", tBefore, tAfter)
        out += "\n"
        let savedTok = (wBefore - wAfter) / 4
        if savedTok != 0 {
            out += savedTok > 0
                ? "➡️ **無駄トークン \(savedTok.commas) 削減**\n\n"
                : "⚠️ **無駄トークンが \((-savedTok).commas) 増加**\n\n"
        }

        // Regressions first: this is the section that should block a change.
        let regressions = pairs.filter { $0.isRegression }.sorted {
            (qualityRank($0.after.layer) - qualityRank($0.before.layer)) < (qualityRank($1.after.layer) - qualityRank($1.before.layer))
        }
        out += "## 🔴 回帰（\(regressions.count) 件）\n\n"
        if regressions.isEmpty {
            out += "回帰なし。\n\n"
        } else {
            out += "| URL | 種別 | before→after | 本文長 Δ | 無駄 Δ |\n|---|---|---|---:|---:|\n"
            for p in regressions {
                var kind: [String] = []
                if p.isLayerRegression { kind.append("層悪化") }
                if p.isContentShrink { kind.append("本文縮小") }
                if p.isWastedRegression { kind.append("無駄増") }
                out += "| \(trunc(p.url, 44)) | \(kind.joined(separator: ",")) | `\(p.before.layer.rawValue)`→`\(p.after.layer.rawValue)` | \(signed(p.contentDelta)) | \(signed(p.wastedDelta)) |\n"
            }
            out += "\n"
        }

        // Improvements.
        let improvements = pairs.filter { $0.isImprovement && !$0.isRegression }.sorted { $0.wastedDelta < $1.wastedDelta }
        out += "## 🟢 改善（\(improvements.count) 件）\n\n"
        if improvements.isEmpty {
            out += "改善なし。\n\n"
        } else {
            out += "| URL | before→after | 本文長 Δ | 無駄 Δ |\n|---|---|---:|---:|\n"
            for p in improvements.prefix(25) {
                out += "| \(trunc(p.url, 44)) | `\(p.before.layer.rawValue)`→`\(p.after.layer.rawValue)` | \(signed(p.contentDelta)) | \(signed(p.wastedDelta)) |\n"
            }
            out += "\n"
        }

        // URLs present in only one report, so a corpus edit is not mistaken for a result change.
        if !added.isEmpty || !removed.isEmpty {
            out += "## コーパス差分\n\n"
            if !added.isEmpty { out += "- 追加: \(added.count) 件\n" }
            if !removed.isEmpty { out += "- 削除: \(removed.count) 件\n" }
            out += "\n"
        }

        return out
    }

    // MARK: helpers
    private static func aggRow(_ name: String, _ b: Int, _ a: Int) -> String {
        "| \(name) | \(b.commas) | \(a.commas) | \(signed(a - b)) |\n"
    }
    private static func signed(_ n: Int) -> String { n > 0 ? "+\(n.commas)" : n.commas }
    private static func trunc(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}

private extension Int {
    var commas: String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
