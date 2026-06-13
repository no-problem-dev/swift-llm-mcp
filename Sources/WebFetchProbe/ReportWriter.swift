import Foundation

// MARK: - ReportWriter

/// 計測結果を Markdown + JSON にまとめて書き出す。
enum ReportWriter {
    static func write(_ results: [ProbeResult], to dir: URL, timestamp: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let md = markdown(results, timestamp: timestamp)
        let mdURL = dir.appendingPathComponent("web-fetch-probe-\(timestamp).md")
        try md.data(using: .utf8)!.write(to: mdURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonURL = dir.appendingPathComponent("web-fetch-probe-\(timestamp).json")
        try encoder.encode(results).write(to: jsonURL)

        print("\n📄 Markdown: \(mdURL.path)")
        print("📄 JSON:     \(jsonURL.path)")
    }

    // MARK: - Markdown 生成

    static func markdown(_ results: [ProbeResult], timestamp: String) -> String {
        var out = "# Web Fetch Tool 安定性レポート\n\n"
        out += "- 生成日時: \(timestamp)\n"
        out += "- 対象: `swift-llm-mcp` `WebToolKit.fetch`（実ネットワーク）\n"
        out += "- URL 件数: \(results.count)\n\n"

        // 全体サマリ
        let okCount = results.filter { $0.layer == .ok }.count
        let thin = results.filter { $0.layer == .okThinContent }.count
        let failed = results.filter { $0.layer.isFailure && $0.layer != .okThinContent }.count
        let unexpected = results.filter { !$0.matchedExpectation }.count
        out += "## 全体サマリ\n\n"
        out += "| 指標 | 件数 | 割合 |\n|---|---:|---:|\n"
        out += row("本文抽出成功 (ok)", okCount, results.count)
        out += row("2xxだが本文薄い (okThinContent)", thin, results.count)
        out += row("失敗 (network/http/その他)", failed, results.count)
        out += row("期待と不一致（想定外の挙動）", unexpected, results.count)
        out += "\n"

        // レイテンシ
        let times = results.map { $0.elapsed }.sorted()
        if !times.isEmpty {
            out += "### レイテンシ\n\n"
            out += "- p50: \(fmt(percentile(times, 0.5)))s / p95: \(fmt(percentile(times, 0.95)))s / max: \(fmt(times.last!))s\n\n"
        }

        // 失敗層の分布
        out += "## 失敗層の分布\n\n"
        out += "| 層 | 説明 | 件数 |\n|---|---|---:|\n"
        for layer in FailureLayer.allCases {
            let c = results.filter { $0.layer == layer }.count
            if c > 0 { out += "| `\(layer.rawValue)` | \(layer.label) | \(c) |\n" }
        }
        out += "\n"

        // カテゴリ別マトリクス
        out += "## カテゴリ別 成功率\n\n"
        out += "| カテゴリ | 件数 | ok | thin | 失敗 | 成功率(ok+thin) |\n|---|---:|---:|---:|---:|---:|\n"
        for cat in ProbeCategory.allCases {
            let rs = results.filter { $0.category == cat }
            guard !rs.isEmpty else { continue }
            let ok = rs.filter { $0.layer == .ok }.count
            let th = rs.filter { $0.layer == .okThinContent }.count
            let fl = rs.count - ok - th
            let rate = Int(Double(ok + th) / Double(rs.count) * 100)
            out += "| \(cat.rawValue) | \(rs.count) | \(ok) | \(th) | \(fl) | \(rate)% |\n"
        }
        out += "\n"

        // 想定外の挙動
        let mismatches = results.filter { !$0.matchedExpectation }
        if !mismatches.isEmpty {
            out += "## ⚠️ 想定外の挙動（期待と不一致）\n\n"
            out += "事前期待と実際の分類がズレたもの。ツールの仕様外の壊れ方、もしくはコーパス側の期待誤り。\n\n"
            out += "| URL | カテゴリ | 期待 | 実際 | 詳細 |\n|---|---|---|---|---|\n"
            for r in mismatches {
                out += "| \(trunc(r.url, 50)) | \(r.category.rawValue) | `\(r.expected.rawValue)` | `\(r.layer.rawValue)` | \(trunc(r.detail, 40)) |\n"
            }
            out += "\n"
        }

        // 失敗 URL 一覧
        let failures = results.filter { $0.layer.isFailure }
        if !failures.isEmpty {
            out += "## 失敗・劣化した URL 一覧\n\n"
            out += "| URL | 層 | 詳細 | 時間(s) |\n|---|---|---|---:|\n"
            for r in failures.sorted(by: { $0.layer.rawValue < $1.layer.rawValue }) {
                out += "| \(trunc(r.url, 50)) | `\(r.layer.rawValue)` | \(trunc(r.detail, 50)) | \(fmt(r.elapsed)) |\n"
            }
            out += "\n"
        }

        // ペイロード品質 / トークン浪費
        out += payloadQuality(results)

        // 改善示唆
        out += improvementSuggestions(results)

        // 全結果
        out += "## 全結果（生データ）\n\n"
        out += "| URL | 層 | 本文長 | ≈tok | 無駄字 | 時間(s) | 期待一致 |\n|---|---|---:|---:|---:|---:|:---:|\n"
        for r in results {
            let wasted = r.noise?.totalWastedChars ?? 0
            out += "| \(trunc(r.url, 48)) | `\(r.layer.rawValue)` | \(r.contentLength) | \(r.approxTokens) | \(wasted) | \(fmt(r.elapsed)) | \(r.matchedExpectation ? "✓" : "✗") |\n"
        }

        return out
    }

    // MARK: - ペイロード品質 / トークン浪費

    /// 「成功」した抽出本文の中に紛れる、LLM トークンを浪費する余計なペイロードを集計。
    static func payloadQuality(_ results: [ProbeResult]) -> String {
        let withNoise = results.filter { $0.noise != nil }
        guard !withNoise.isEmpty else { return "" }

        var out = "## ペイロード品質 / トークン浪費分析\n\n"
        out += "成功（ok / thin）した抽出本文を対象に、ナビ残骸・Cookie バナー・base64画像・"
        out += "重複行・トラッキングURL 等「LLM が読む価値のない余計なペイロード」を定量化。\n\n"

        let totalTokens = withNoise.reduce(0) { $0 + $1.approxTokens }
        let totalWasted = withNoise.reduce(0) { $0 + ($1.noise?.totalWastedChars ?? 0) }
        out += "- 分析対象: \(withNoise.count) ページ\n"
        out += "- 概算総トークン（取得本文ベース, ≈utf8÷4）: **\(totalTokens.formattedThousands)**\n"
        out += "- 無駄と推定される文字数合計: **\(totalWasted.formattedThousands)** 字（≈ \((totalWasted / 4).formattedThousands) トークン）\n\n"

        // シグナル別集計
        out += "### ノイズ種別ごとの集計\n\n"
        out += "| ノイズ種別 | 検出ページ数 | 無駄文字(合計) | ≈トークン |\n|---|---:|---:|---:|\n"
        for signal in NoiseSignal.allCases {
            let pages = withNoise.filter { ($0.noise?.countsBySignal[signal.rawValue] ?? 0) > 0 }
            guard !pages.isEmpty else { continue }
            let wasted = pages.reduce(0) { $0 + ($1.noise?.wastedCharsBySignal[signal.rawValue] ?? 0) }
            out += "| \(signal.label) | \(pages.count) | \(wasted.formattedThousands) | \((wasted / 4).formattedThousands) |\n"
        }
        out += "\n"

        // 無駄トークンが多い Top ページ
        let ranked = withNoise
            .map { ($0, $0.noise?.totalWastedChars ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(15)
        if !ranked.isEmpty {
            out += "### 無駄ペイロードが多い Top ページ\n\n"
            out += "_無駄字はシグナル別推定の合算（上限推定。複数シグナルが重なる箇所は二重計上されうる）。_\n\n"
            out += "| URL | 本文長 | 無駄字 | 無駄率 | 主なノイズ |\n|---|---:|---:|---:|---|\n"
            for (r, wasted) in ranked {
                let pct = r.contentLength > 0 ? min(100, Int(Double(wasted) / Double(max(r.contentLength, 1)) * 100)) : 0
                let kinds = (r.noise?.countsBySignal.keys.compactMap { NoiseSignal(rawValue: $0)?.label } ?? []).sorted().joined(separator: ", ")
                out += "| \(trunc(r.url, 44)) | \(r.contentLength) | \(wasted) | \(pct)% | \(trunc(kinds, 40)) |\n"
            }
            out += "\n"
        }

        // 代表的な無駄スニペット
        let samples = withNoise.compactMap { r -> String? in
            guard let s = r.noise?.samples, !s.isEmpty else { return nil }
            return "- `\(trunc(r.url, 40))`: " + s.joined(separator: " / ")
        }.prefix(12)
        if !samples.isEmpty {
            out += "### 検出スニペット例\n\n"
            out += samples.joined(separator: "\n") + "\n\n"
        }

        return out
    }

    // MARK: - 改善示唆（データ駆動）

    static func improvementSuggestions(_ results: [ProbeResult]) -> String {
        var out = "## 改善示唆\n\n"
        var any = false

        let blocked = results.filter { $0.layer == .httpClientError && ($0.detail.contains("403") || $0.detail.contains("401") || $0.detail.contains("429")) }
        if blocked.count >= 1 {
            any = true
            out += "- **Bot ブロック (\(blocked.count)件)**: 静的 User-Agent が WAF に弾かれている。User-Agent ローテーション、`Accept`/`Sec-Fetch-*` ヘッダ補完、429 への指数バックオフ + リトライを検討。\n"
        }
        let thin = results.filter { $0.layer == .okThinContent }
        if thin.count >= 1 {
            any = true
            out += "- **本文が薄い (\(thin.count)件)**: SPA / JS 描画ページで Readability が本文を拾えていない。ヘッドレスブラウザ（WKWebView 等）での描画後抽出 fallback、または `<noscript>`/OGP メタからの最低限抽出を検討。\n"
        }
        let enc = results.filter { $0.layer == .encoding }
        if enc.count >= 1 {
            any = true
            out += "- **エンコーディング不能 (\(enc.count)件)**: charset フォールバックチェーンの取りこぼし。HTML `<meta charset>` / BOM の事前検出を追加。\n"
        }
        let tls = results.filter { $0.layer == .networkTLS }
        if tls.count >= 1 {
            any = true
            out += "- **TLS エラー (\(tls.count)件)**: 証明書エラーは仕様通り遮断されている（安全）。ユーザー向けに「証明書エラー」と明示するメッセージ整備のみ。\n"
        }
        let timeout = results.filter { $0.layer == .networkTimeout }
        if timeout.count >= 1 {
            any = true
            out += "- **タイムアウト (\(timeout.count)件)**: タイムアウト値の調整、もしくは遅いサーバーへのリトライ戦略を検討。\n"
        }
        let server = results.filter { $0.layer == .httpServerError }
        if server.count >= 1 {
            any = true
            out += "- **5xx (\(server.count)件)**: サーバー側一時障害。指数バックオフ付きリトライで回復可能なケースが多い。\n"
        }
        let large = results.filter { $0.layer == .contentTooLarge }
        if large.count >= 1 {
            any = true
            out += "- **サイズ超過/バイナリ (\(large.count)件)**: 仕様通りの遮断。`fetch_headers` で事前に Content-Type/Content-Length を確認するフローへ誘導すると無駄な転送を削減できる。\n"
        }
        // ペイロード品質起点
        let withNoise = results.filter { $0.noise != nil }
        let base64Pages = withNoise.filter { ($0.noise?.countsBySignal[NoiseSignal.base64DataURI.rawValue] ?? 0) > 0 }
        if !base64Pages.isEmpty {
            any = true
            out += "- **base64 インライン画像が本文に混入 (\(base64Pages.count)件)**: SwiftSoupContentExtractor が `data:...;base64,...` を除去していない。LLM には無意味な巨大 blob。抽出時に `data:` URI を持つ要素/属性を strip すべき（最優先のトークン削減）。\n"
        }
        let linkDense = withNoise.filter { ($0.noise?.countsBySignal[NoiseSignal.linkDense.rawValue] ?? 0) > 0 }
        if !linkDense.isEmpty {
            any = true
            out += "- **リンク過多なナビ残骸 (\(linkDense.count)件)**: Readability がメニュー/リンク集を本文として誤抽出。リンク密度が高いブロックの減点強化を検討。\n"
        }
        let htmlResidue = withNoise.filter { ($0.noise?.countsBySignal[NoiseSignal.htmlResidue.rawValue] ?? 0) > 0 }
        if !htmlResidue.isEmpty {
            any = true
            out += "- **HTML/CSS/JS 残骸 (\(htmlResidue.count)件)**: Markdown 化後に生タグ/スタイル断片が残存。抽出後のサニタイズ強化でトークン削減。\n"
        }
        let dup = withNoise.filter { ($0.noise?.countsBySignal[NoiseSignal.duplicateLines.rawValue] ?? 0) > 0 }
        if !dup.isEmpty {
            any = true
            out += "- **重複行 (\(dup.count)件)**: 同一行の反復（ナビ/リストの取りこぼし）。抽出後に連続重複行を畳むだけで削減可能。\n"
        }

        let unknown = results.filter { $0.layer == .unknown }
        if unknown.count >= 1 {
            any = true
            out += "- **未分類エラー (\(unknown.count)件)**: classifier に未対応のエラー型。詳細を確認し分類を拡張すべき。\n"
        }
        if !any { out += "- 目立った劣化なし。\n" }
        out += "\n"
        return out
    }

    // MARK: - helpers

    private static func row(_ name: String, _ count: Int, _ total: Int) -> String {
        let pct = total > 0 ? Int(Double(count) / Double(total) * 100) : 0
        return "| \(name) | \(count) | \(pct)% |\n"
    }
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, Int(Double(sorted.count - 1) * p))
        return sorted[idx]
    }
    private static func fmt(_ d: Double) -> String { String(format: "%.2f", d) }
    private static func trunc(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}

private extension Int {
    var formattedThousands: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
