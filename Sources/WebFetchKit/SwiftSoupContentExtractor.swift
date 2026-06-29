import Foundation
import SwiftSoup

// MARK: - SwiftSoupContentExtractor

/// SwiftSoupを使用したWebコンテンツ抽出のデフォルト実装
///
/// 3つの主要な責務を持つ：
/// 1. **DOMクリーニング** — 不要な要素（script, style, nav等）を除去
/// 2. **Readabilityスコアリング** — 本文コンテンツの自動検出
/// 3. **Markdown変換** — DOMを再帰的にMarkdownへ変換
///
/// ## 使用例
///
/// ```swift
/// let extractor = SwiftSoupContentExtractor()
/// let result = try extractor.extract(html: htmlString, url: URL(string: "https://example.com")!)
/// print(result.content) // Markdown
/// ```
public struct SwiftSoupContentExtractor: WebContentExtractor, Sendable {

    public init() {}

    // MARK: - WebContentExtractor

    public func extract(html: String, url: URL) throws -> ExtractedContent {
        let doc = try SwiftSoup.parse(html, url.absoluteString)

        // メタデータ抽出（クリーニング前に実施）
        let metadata = Self.extractMetadata(from: doc)
        let title = Self.extractTitle(from: doc, metadata: metadata)

        // DOMクリーニング
        Self.cleanDOM(doc)

        // Readabilityスコアリングで本文要素を特定
        let contentElement = try Self.findMainContent(in: doc)

        // 選択済み本文要素の「中」のナビ/TOC/関連リンク集を除去する。
        // 本文選択の後に行うことで、選択を痩せさせず本文内ノイズだけを掃除する。
        Self.removeNavigationalLinkBlocks(in: contentElement)

        // Markdown変換
        let markdown = Self.convertToMarkdown(element: contentElement, baseURL: url)

        // 後処理
        let cleaned = Self.postProcess(markdown)

        // 本文抽出が「ほぼ空」のときだけフォールバックする。短いが正常な抽出（記事）は
        // body-text 等で汚染せずそのまま返す。
        if cleaned.count < Self.fallbackTriggerThreshold {
            let fallback = Self.buildFallbackContent(doc: doc, metadata: metadata, primary: cleaned)
            return ExtractedContent(title: title, content: fallback, metadata: metadata)
        }

        return ExtractedContent(title: title, content: cleaned, metadata: metadata)
    }

    /// 抽出結果がこの文字数未満なら「ほぼ空＝抽出失敗」とみなしフォールバックを試みる。
    /// 短い正常記事を巻き込まないよう低めに設定する。
    static let fallbackTriggerThreshold = 50

    /// 本文抽出がほぼ空のときのフォールバック内容を構築する。
    ///
    /// 1. body の可視テキスト（リンク密度が低い=prose のときのみ）で
    ///    table/font レイアウト等の取りこぼしを救済する（例: paulgraham）。
    /// 2. それでも薄ければ OGP/meta description を最低限の本文として返す（SPA/paywall）。
    /// 3. どちらも無ければ primary を返す。リンク集約ページの nav を floor として
    ///    戻すと P1 で除去したノイズを再注入するため行わない。
    static func buildFallbackContent(doc: Document, metadata: [String: String], primary: String) -> String {
        // 1. body 可視テキスト（prose のときのみ採用）。table/font レイアウト救済。
        if let body = doc.body(), let bodyText = try? body.text() {
            let normalized = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.count >= 200, normalized.count > primary.count {
                let linkText = (try? body.select("a").text()) ?? ""
                let density = normalized.isEmpty ? 1.0 : Double(linkText.count) / Double(normalized.count)
                if density < 0.5 {
                    return normalized
                }
            }
        }
        // 2. メタディスクリプション（SPA/paywall/nav-only ページの最低限の本文）
        if let desc = metadata["og:description"] ?? metadata["description"], !desc.isEmpty {
            return desc
        }
        return primary
    }

    // MARK: - (A) DOM Cleaning

    /// 不要な要素を除去
    static func cleanDOM(_ doc: Document) {
        let selectorsToRemove = [
            "script", "style", "nav", "footer", "aside", "header",
            "svg", "noscript", "form", "iframe", "button",
            "[role=navigation]", "[role=banner]", "[role=complementary]", "[role=contentinfo]",
        ]
        let selector = selectorsToRemove.joined(separator: ", ")
        if let elements = try? doc.select(selector) {
            _ = try? elements.remove()
        }
        // コメントノードも除去
        if let body = doc.body() {
            removeComments(from: body)
        }
    }

    /// HTMLコメントを再帰的に除去
    private static func removeComments(from node: Node) {
        var i = 0
        while i < node.childNodeSize() {
            let child = node.childNode(i)
            if child is Comment {
                try? child.remove()
            } else {
                removeComments(from: child)
                i += 1
            }
        }
    }

    // MARK: - (A2) Navigational Link Block Removal

    /// 高リンク密度のナビ/TOC/関連リンク集ブロックを除去する。
    ///
    /// `cleanDOM` で nav/header/footer タグは除去済みのため、ここでは
    /// `<div class=toc>` `<ul class=menu>` 等、タグだけでは判別できない
    /// リンク集を狙う。本文（prose）と長文リンク（記事タイトル一覧）は保護する。
    static func removeNavigationalLinkBlocks(in root: Element) {
        let candidates = (try? root.select("ul, ol, div, section").array()) ?? []
        for el in candidates {
            // 既に親ごと除去済みならスキップ
            guard el.parent() != nil else { continue }

            let links = (try? el.select("a").array()) ?? []
            guard links.count >= 3 else { continue }

            let fullText = (try? el.text()) ?? ""
            guard !fullText.isEmpty else { continue }
            let linkText = (try? el.select("a").text()) ?? ""
            let linkDensity = Double(linkText.count) / Double(fullText.count)
            guard linkDensity > 0.5 else { continue }

            // 純粋ナビガード: リンク以外のテキストが一定量あれば本文/データとみなし保持する。
            // <p> に限らず <li>/<dd>/表など全テキストを対象にするため、Wikipedia の
            // データブロックや巨大 TOC（非リンクの節番号・説明が多い）を巻き込まない。
            let nonLinkTextLen = max(0, fullText.count - linkText.count)
            if nonLinkTextLen > 300 { continue }

            // ネガティブな class/id シグナルを持つブロックのみ除去する（保守的）。
            // 無印（class 無し）の本文・データ・記事タイトル一覧を巻き込まないため、
            // 密度だけでの除去はしない。明示的にナビ/TOC/関連と分かるものだけ落とす。
            let classId = (((try? el.className()) ?? "") + " " + el.id()).lowercased()
            let negativePatterns = [
                "nav", "menu", "toc", "sidebar", "footer", "header", "related",
                "breadcrumb", "pagination", "pager", "social", "share",
                "widget", "promo", "recommend", "sitemap", "drawer", "offcanvas",
            ]
            let hasNegativeSignal = negativePatterns.contains { classId.contains($0) }
            if hasNegativeSignal {
                try? el.remove()
            }
        }
    }

    // MARK: - (B) Readability Scoring

    /// 本文コンテンツ要素を特定
    static func findMainContent(in doc: Document) throws -> Element {
        // 1. <article> or <main> があれば即採用
        if let article = try? doc.select("article").first(), let text = try? article.text(), !text.isEmpty {
            return article
        }
        if let main = try? doc.select("main").first(), let text = try? main.text(), !text.isEmpty {
            return main
        }

        // 2. 全 div/section/td/pre をスキャンしスコア付与
        guard let body = doc.body() else {
            throw SwiftSoupExtractorError.noBody
        }

        let candidates = try body.select("div, section, td, pre")
        var bestScore = 0
        var bestElement: Element?

        for candidate in candidates.array() {
            let score = scoreElement(candidate)
            if score > bestScore {
                bestScore = score
                bestElement = candidate
            }
        }

        // 3. 最高スコア > 20 の要素を本文、なければ body フォールバック
        if bestScore > 20, let best = bestElement {
            return best
        }

        return body
    }

    /// 要素のReadabilityスコアを計算
    static func scoreElement(_ element: Element) -> Int {
        var score = 0

        // クラス/IDのセマンティック判定
        let classId = ((try? element.className()) ?? "") + " " + (element.id())
        let classIdLower = classId.lowercased()

        let positivePatterns = [
            "article", "body", "content", "entry", "main", "page",
            "post", "text", "blog", "story", "prose",
        ]
        let negativePatterns = [
            "combx", "comment", "contact", "foot", "footer",
            "masthead", "media", "meta", "nav", "outbrain",
            "promo", "related", "scroll", "shoutbox", "sidebar",
            "sponsor", "shopping", "tags", "tool", "widget", "banner",
        ]

        for pattern in positivePatterns {
            if classIdLower.contains(pattern) {
                score += 25
                break
            }
        }
        for pattern in negativePatterns {
            if classIdLower.contains(pattern) {
                score -= 25
                break
            }
        }

        // テキスト長ボーナス
        let textLength = element.ownText().count
        if textLength > 500 {
            score += 30
        } else if textLength > 100 {
            score += 20
        }

        // 直接 <p> 子要素数
        let directParagraphs = element.children().array().filter { $0.tagName() == "p" }
        score += directParagraphs.count * 10

        // リンク密度ペナルティ
        let fullText = (try? element.text()) ?? ""
        let linkText = (try? element.select("a").text()) ?? ""
        if !fullText.isEmpty {
            let linkDensity = Double(linkText.count) / Double(fullText.count)
            if linkDensity > 0.5 {
                score -= 50
            }
        }

        // カンマ/読点の数
        let commaCount = fullText.filter { $0 == "," || $0 == "\u{3001}" }.count
        score += commaCount * 3

        return score
    }

    // MARK: - (C) Markdown Conversion

    /// DOM要素をMarkdownに変換
    static func convertToMarkdown(element: Element, baseURL: URL) -> String {
        var lines: [String] = []
        walkNode(element, baseURL: baseURL, lines: &lines, listDepth: 0, listIndex: nil)
        return lines.joined(separator: "\n")
    }

    /// ノードを再帰的にウォーク
    private static func walkNode(
        _ node: Node,
        baseURL: URL,
        lines: inout [String],
        listDepth: Int,
        listIndex: Int?
    ) {
        if let textNode = node as? TextNode {
            let text = textNode.getWholeText()
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(text)
            }
            return
        }

        guard let element = node as? Element else {
            // 他のノードタイプは子をウォーク
            for child in node.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            }
            return
        }

        let tag = element.tagName().lowercased()

        switch tag {
        // 見出し
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.last!))!
            let prefix = String(repeating: "#", count: level)
            let text = (try? element.text()) ?? ""
            if !text.isEmpty {
                lines.append("")
                lines.append("\(prefix) \(text)")
                lines.append("")
            }

        // リンク
        case "a":
            let text = (try? element.text()) ?? ""
            let href = resolveURL(try? element.attr("href"), base: baseURL)
            if !text.isEmpty, let href = href {
                lines.append("[\(text)](\(href))")
            } else if !text.isEmpty {
                lines.append(text)
            }

        // 画像
        case "img":
            let alt = (try? element.attr("alt")) ?? ""
            let src = resolveURL(try? element.attr("src"), base: baseURL)
            if let src = src {
                lines.append("![\(alt)](\(src))")
            }

        // 強調
        case "strong", "b":
            let text = (try? element.text()) ?? ""
            if !text.isEmpty {
                lines.append("**\(text)**")
            }

        case "em", "i":
            let text = (try? element.text()) ?? ""
            if !text.isEmpty {
                lines.append("*\(text)*")
            }

        // インラインコード
        case "code":
            // 親が <pre> の場合はブロックコードとして処理しない（pre側で処理）
            if element.parent()?.tagName().lowercased() == "pre" {
                let text = (try? element.text()) ?? ""
                // 中身が空のコードブロックは空フェンスのノイズになるため出力しない
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                let lang = (try? element.className()) ?? ""
                let langHint = lang.replacingOccurrences(of: "language-", with: "")
                    .components(separatedBy: " ").first ?? ""
                lines.append("")
                lines.append("```\(langHint)")
                lines.append(text)
                lines.append("```")
                lines.append("")
            } else {
                let text = (try? element.text()) ?? ""
                if !text.isEmpty {
                    lines.append("`\(text)`")
                }
            }

        // コードブロック
        case "pre":
            // <pre><code>...</code></pre> パターンを検出
            if let codeChild = element.children().array().first(where: { $0.tagName() == "code" }) {
                walkNode(codeChild, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            } else {
                let text = (try? element.text()) ?? ""
                // 中身が空のコードブロックは出力しない
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                lines.append("")
                lines.append("```")
                lines.append(text)
                lines.append("```")
                lines.append("")
            }

        // 順序なしリスト
        case "ul":
            lines.append("")
            for child in element.children().array() where child.tagName() == "li" {
                let indent = String(repeating: "  ", count: listDepth)
                var itemLines: [String] = []
                walkNode(child, baseURL: baseURL, lines: &itemLines, listDepth: listDepth + 1, listIndex: nil)
                let itemText = itemLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !itemText.isEmpty {
                    lines.append("\(indent)- \(itemText)")
                }
            }
            lines.append("")

        // 順序付きリスト
        case "ol":
            lines.append("")
            for (idx, child) in element.children().array().filter({ $0.tagName() == "li" }).enumerated() {
                let indent = String(repeating: "  ", count: listDepth)
                var itemLines: [String] = []
                walkNode(child, baseURL: baseURL, lines: &itemLines, listDepth: listDepth + 1, listIndex: idx + 1)
                let itemText = itemLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !itemText.isEmpty {
                    lines.append("\(indent)\(idx + 1). \(itemText)")
                }
            }
            lines.append("")

        // リストアイテム（直接のウォークでは子を展開）
        case "li":
            for child in element.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            }

        // 引用
        case "blockquote":
            var quotedLines: [String] = []
            for child in element.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &quotedLines, listDepth: listDepth, listIndex: listIndex)
            }
            let quoted = quotedLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !quoted.isEmpty {
                lines.append("")
                for line in quoted.components(separatedBy: "\n") {
                    lines.append("> \(line)")
                }
                lines.append("")
            }

        // テーブル
        case "table":
            let tableMarkdown = convertTable(element, baseURL: baseURL)
            if !tableMarkdown.isEmpty {
                lines.append("")
                lines.append(tableMarkdown)
                lines.append("")
            }

        // 段落
        case "p":
            var pLines: [String] = []
            for child in element.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &pLines, listDepth: listDepth, listIndex: listIndex)
            }
            let text = pLines.joined(separator: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append("")
                lines.append(text)
                lines.append("")
            }

        // 改行
        case "br":
            lines.append("")

        // 水平線
        case "hr":
            lines.append("")
            lines.append("---")
            lines.append("")

        // ブロック要素（div, section等）
        case "div", "section", "article", "main", "span", "figure", "figcaption", "details", "summary":
            for child in element.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            }

        // thead, tbody, tr 等のテーブル内部要素はスキップ（table で処理済み）
        case "thead", "tbody", "tfoot", "tr", "th", "td", "caption", "colgroup", "col":
            break

        default:
            // 未知の要素は子を展開
            for child in element.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            }
        }
    }

    /// テーブルをGFM Markdown形式に変換
    private static func convertTable(_ table: Element, baseURL: URL) -> String {
        var headerCells: [String] = []
        var rows: [[String]] = []

        // ヘッダー行
        if let thead = try? table.select("thead").first() {
            if let tr = try? thead.select("tr").first() {
                headerCells = (try? tr.select("th, td").array().map { (try? $0.text()) ?? "" }) ?? []
            }
        }

        // ヘッダーが thead にない場合、最初の tr から取得
        if headerCells.isEmpty {
            if let firstRow = try? table.select("tr").first() {
                let ths = (try? firstRow.select("th").array()) ?? []
                if !ths.isEmpty {
                    headerCells = ths.map { (try? $0.text()) ?? "" }
                }
            }
        }

        // ボディ行
        let allRows = (try? table.select("tr").array()) ?? []
        let startIndex = headerCells.isEmpty ? 0 : 1
        for i in startIndex..<allRows.count {
            let cells = (try? allRows[i].select("td, th").array().map { (try? $0.text()) ?? "" }) ?? []
            if !cells.isEmpty {
                rows.append(cells)
            }
        }

        // ヘッダーがない場合、最初の行をヘッダーに昇格
        if headerCells.isEmpty, !rows.isEmpty {
            headerCells = rows.removeFirst()
        }

        guard !headerCells.isEmpty else { return "" }

        // カラム数を統一
        let colCount = max(headerCells.count, rows.map { $0.count }.max() ?? 0)
        let normalizedHeader = headerCells + Array(repeating: "", count: max(0, colCount - headerCells.count))

        var result = "| " + normalizedHeader.joined(separator: " | ") + " |"
        result += "\n| " + normalizedHeader.map { _ in "---" }.joined(separator: " | ") + " |"

        for row in rows {
            let normalizedRow = row + Array(repeating: "", count: max(0, colCount - row.count))
            result += "\n| " + normalizedRow.joined(separator: " | ") + " |"
        }

        return result
    }

    // MARK: - Metadata Extraction

    /// メタデータを抽出
    static func extractMetadata(from doc: Document) -> [String: String] {
        var metadata: [String: String] = [:]

        // og:title
        if let ogTitle = try? doc.select("meta[property=og:title]").first()?.attr("content"),
           !ogTitle.isEmpty {
            metadata["og:title"] = ogTitle
        }

        // description
        if let desc = try? doc.select("meta[name=description]").first()?.attr("content"),
           !desc.isEmpty {
            metadata["description"] = desc
        }

        // og:description
        if let ogDesc = try? doc.select("meta[property=og:description]").first()?.attr("content"),
           !ogDesc.isEmpty {
            metadata["og:description"] = ogDesc
        }

        // og:image
        if let ogImage = try? doc.select("meta[property=og:image]").first()?.attr("content"),
           !ogImage.isEmpty {
            metadata["og:image"] = ogImage
        }

        // canonical
        if let canonical = try? doc.select("link[rel=canonical]").first()?.attr("href"),
           !canonical.isEmpty {
            metadata["canonical"] = canonical
        }

        return metadata
    }

    /// タイトルを抽出（og:title > <title> の優先順位）
    static func extractTitle(from doc: Document, metadata: [String: String]) -> String? {
        if let ogTitle = metadata["og:title"] {
            return ogTitle
        }
        if let title = try? doc.title(), !title.isEmpty {
            return title
        }
        return nil
    }

    // MARK: - Helpers

    /// 相対URLを絶対URLに解決
    private static func resolveURL(_ href: String?, base: URL) -> String? {
        guard let href = href, !href.isEmpty else { return nil }
        // data: URL, javascript: はスキップ
        if href.hasPrefix("data:") || href.hasPrefix("javascript:") || href.hasPrefix("#") {
            return nil
        }
        let absolute: String?
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            absolute = href
        } else {
            absolute = URL(string: href, relativeTo: base)?.absoluteString
        }
        return absolute.map(stripTrackingParams)
    }

    /// トラッキングクエリパラメータ（utm_* / gclid / fbclid 等）を除去して URL を短縮する。
    static func stripTrackingParams(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString),
              let items = components.queryItems, !items.isEmpty else {
            return urlString
        }
        let trackingExact: Set<String> = ["gclid", "fbclid", "mc_eid", "igshid", "yclid", "msclkid", "_hsenc", "_hsmi"]
        let filtered = items.filter { item in
            let name = item.name.lowercased()
            if name.hasPrefix("utm_") { return false }
            return !trackingExact.contains(name)
        }
        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.string ?? urlString
    }

    /// 後処理: data: URI 除去、連続空行圧縮、行末空白除去、連続同一行の畳み込み
    static func postProcess(_ markdown: String) -> String {
        // base64 data URI の巨大 blob は LLM トークンの純粋な浪費なので除去する
        let deDataURI = markdown.replacingOccurrences(
            of: "data:[^;\\s]+;base64,[A-Za-z0-9+/=]{100,}",
            with: "[data-uri removed]",
            options: .regularExpression
        )
        let lines = deDataURI.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }

        // 連続空行を最大1つに圧縮 + 連続する同一行を1つに畳み込む
        var result: [String] = []
        var previousWasEmpty = false
        var previousLine: String?

        for line in lines {
            if line.isEmpty {
                if !previousWasEmpty {
                    result.append("")
                }
                previousWasEmpty = true
                previousLine = nil
                continue
            }
            // 直前と同一の非空行は重複ノイズとして畳む。
            // ただしテーブル行（| 始まり）は構造保持のため畳まない。
            if let prev = previousLine, prev == line, !line.hasPrefix("|") {
                continue
            }
            result.append(line)
            previousWasEmpty = false
            previousLine = line
        }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

enum SwiftSoupExtractorError: Error, LocalizedError {
    case noBody

    var errorDescription: String? {
        switch self {
        case .noBody:
            return "HTML document has no <body> element."
        }
    }
}
