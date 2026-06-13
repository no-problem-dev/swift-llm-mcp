import Foundation

// MARK: - ReportDiff
//
// 2 つの probe レポート（JSON = [ProbeResult]）を突き合わせ、抽出器/フェッチ改修の
// 効果を回帰ゲートとして可視化する。
//   - 改善: 失敗→成功、thin→ok、無駄トークン削減
//   - 回帰: 成功→失敗、ok→thin、本文の不当な縮小（過剰サニタイズ）、無駄増加
//
// URL をキーに突合する。コーパスが変わって増減した URL も検出する。

enum ReportDiff {

    /// 抽出品質の良さ順位（高いほど良い）
    static func qualityRank(_ layer: FailureLayer) -> Int {
        switch layer {
        case .ok: return 2
        case .okThinContent: return 1
        default: return 0
        }
    }

    /// 本文がこの割合を超えて縮小し、かつ絶対量も大きい場合は「良コンテンツ喪失」の疑い
    static let shrinkRatioThreshold = 0.25
    static let shrinkAbsThreshold = 1000

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

        /// 層が悪化した
        var isLayerRegression: Bool { rankDelta < 0 }
        /// 両方とも成功扱いだが本文が不当に縮小（過剰除去の疑い）
        var isContentShrink: Bool {
            guard qualityRank(before.layer) >= 1, qualityRank(after.layer) >= 1 else { return false }
            guard before.contentLength > 0 else { return false }
            let ratio = Double(before.contentLength - after.contentLength) / Double(before.contentLength)
            return ratio > shrinkRatioThreshold && (before.contentLength - after.contentLength) > shrinkAbsThreshold
        }
        /// 無駄増は「層が改善していない」場合のみ回帰とみなす
        /// （failure→success で新たに本文を得たケースは回帰ではない）
        var isWastedRegression: Bool { wastedDelta > 50 && rankDelta <= 0 }
        var isRegression: Bool { isLayerRegression || isContentShrink || isWastedRegression }
        var isImprovement: Bool { rankDelta > 0 || wastedDelta < -50 }
    }

    static func loadResults(_ path: String) throws -> [ProbeResult] {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ProbeResult].self, from: data)
    }

    /// 2 ファイルを比較して Markdown を返す。
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

        // 集計 delta
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

        // 回帰
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

        // 改善
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

        // コーパス増減
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
