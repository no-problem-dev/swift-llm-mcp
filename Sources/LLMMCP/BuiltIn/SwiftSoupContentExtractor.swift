import Foundation
import SwiftSoup

// MARK: - SwiftSoupContentExtractor

/// SwiftSoupを使用したWebコンテンツ抽出のデフォルト実装
///
/// 3つの主要な責務を持ちます：
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

        // Markdown変換
        let markdown = Self.convertToMarkdown(element: contentElement, baseURL: url)

        // 後処理
        let cleaned = Self.postProcess(markdown)

        return ExtractedContent(title: title, content: cleaned, metadata: metadata)
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
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            return href
        }
        return URL(string: href, relativeTo: base)?.absoluteString
    }

    /// 後処理: 連続空行圧縮、行末空白除去
    static func postProcess(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }

        // 連続空行を最大1つに圧縮
        var result: [String] = []
        var previousWasEmpty = false

        for line in lines {
            if line.isEmpty {
                if !previousWasEmpty {
                    result.append("")
                }
                previousWasEmpty = true
            } else {
                result.append(line)
                previousWasEmpty = false
            }
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
