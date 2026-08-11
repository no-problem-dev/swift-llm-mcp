import Foundation
import SwiftSoup

// MARK: - SwiftSoupContentExtractor

/// The default HTML-to-Markdown extractor, built on SwiftSoup.
///
/// It strips chrome (`script`, `style`, `nav`, `footer`, ...), scores the remaining
/// elements to guess which one holds the article, prunes link-heavy blocks inside that
/// element, then walks it into Markdown.
///
/// Everything is heuristic, so it can pick the wrong element. The three tuned constants
/// worth knowing: a candidate needs a readability score above 20 to beat a plain `<body>`
/// fallback, a block is only pruned as navigation when its links exceed half its text
/// *and* its class or id names one of the navigation patterns, and an extraction under
/// 50 characters is replaced by the body text or the meta description.
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

        // Read metadata before cleaning, because cleanDOM removes the <head> children it lives in.
        let metadata = Self.extractMetadata(from: doc)
        let title = Self.extractTitle(from: doc, metadata: metadata)

        Self.cleanDOM(doc)

        let contentElement = try Self.findMainContent(in: doc)

        // Prune navigation *inside* the chosen element. Doing it after selection means a
        // link-heavy page still gets a candidate chosen from its full markup.
        Self.removeNavigationalLinkBlocks(in: contentElement)

        let markdown = Self.convertToMarkdown(element: contentElement, baseURL: url)
        let cleaned = Self.postProcess(markdown)

        // Only a near-empty extraction falls back. A short but genuine article is returned
        // as-is rather than padded with body text.
        if cleaned.count < Self.fallbackTriggerThreshold {
            let fallback = Self.buildFallbackContent(doc: doc, metadata: metadata, primary: cleaned)
            return ExtractedContent(title: title, content: fallback, metadata: metadata)
        }

        return ExtractedContent(title: title, content: cleaned, metadata: metadata)
    }

    /// Character count below which an extraction counts as failed and the fallback runs.
    ///
    /// Deliberately low so that a short but real article is not thrown away.
    static let fallbackTriggerThreshold = 50

    /// Builds replacement content when the main extraction came back near-empty.
    ///
    /// Tries the body's visible text first, but only when its link density is under 0.5 —
    /// that rescues table- and `<font>`-based layouts the readability pass cannot score
    /// (paulgraham.com is the standing example). Failing that, it returns the OpenGraph or
    /// meta description, which is all a paywalled page or an unrendered SPA has to offer.
    ///
    /// Navigation is never used as a floor: returning the link list would put back exactly
    /// the noise the cleaning pass removed.
    static func buildFallbackContent(doc: Document, metadata: [String: String], primary: String) -> String {
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
        // Meta description: the minimum viable body for an SPA, paywall or nav-only page.
        if let desc = metadata["og:description"] ?? metadata["description"], !desc.isEmpty {
            return desc
        }
        return primary
    }

    // MARK: - (A) DOM Cleaning

    /// Removes page chrome and HTML comments in place, mutating the document.
    ///
    /// `header`, `footer`, `nav` and `aside` go regardless of what they contain, so a page
    /// whose article sits inside `<header>` loses its body here.
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
        if let body = doc.body() {
            removeComments(from: body)
        }
    }

    /// Removes comment nodes from a subtree, depth first.
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

    /// Removes link-dense navigation, tables of contents and "related" blocks from a subtree.
    ///
    /// `cleanDOM` already took the semantic tags, so what is left are the ones tags cannot
    /// identify: `<div class=toc>`, `<ul class=menu>` and friends.
    ///
    /// Three conditions must all hold before a block is removed: at least three links, a
    /// link density above 0.5, and fewer than 300 non-link characters. A class or id
    /// matching a navigation pattern is required on top of that. Density alone would take
    /// out unlabelled article indexes and Wikipedia data blocks, so it is never sufficient.
    static func removeNavigationalLinkBlocks(in root: Element) {
        let candidates = (try? root.select("ul, ol, div, section").array()) ?? []
        for el in candidates {
            // Already gone, removed along with an ancestor earlier in this loop.
            guard el.parent() != nil else { continue }

            let links = (try? el.select("a").array()) ?? []
            guard links.count >= 3 else { continue }

            let fullText = (try? el.text()) ?? ""
            guard !fullText.isEmpty else { continue }
            let linkText = (try? el.select("a").text()) ?? ""
            let linkDensity = Double(linkText.count) / Double(fullText.count)
            guard linkDensity > 0.5 else { continue }

            // Enough non-link text means this is content, not navigation. Counting all text
            // rather than just <p> keeps Wikipedia data blocks and big tables of contents —
            // which carry long non-link section numbers and captions — out of the crosshairs.
            let nonLinkTextLen = max(0, fullText.count - linkText.count)
            if nonLinkTextLen > 300 { continue }

            // Require an explicit naming signal as well. Without it, an unlabelled list of
            // article titles looks identical to a menu and would be removed.
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

    /// Picks the element most likely to hold the article.
    ///
    /// The first non-empty `<article>` or `<main>` wins outright, without scoring. Failing
    /// that, every `div`, `section`, `td` and `pre` is scored and the best one is taken,
    /// but only if it clears 20 points — otherwise the whole `<body>` is returned, which
    /// is how boilerplate ends up in the output on pages with no structural markup.
    ///
    /// - Throws: ``SwiftSoupExtractorError/noBody`` when the document has no `<body>`.
    static func findMainContent(in doc: Document) throws -> Element {
        if let article = try? doc.select("article").first(), let text = try? article.text(), !text.isEmpty {
            return article
        }
        if let main = try? doc.select("main").first(), let text = try? main.text(), !text.isEmpty {
            return main
        }

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

        if bestScore > 20, let best = bestElement {
            return best
        }

        return body
    }

    /// Scores one element on how much it looks like article body text.
    ///
    /// Positive: a content-flavoured class or id (+25, once), long own-text (+20 or +30),
    /// direct `<p>` children (+10 each), commas and Japanese ideographic commas (+3 each).
    /// Negative: a chrome-flavoured class or id (-25, once) and a link density over 0.5 (-50).
    ///
    /// The comma bonus is unbounded, so a very long page of prose can score into the
    /// thousands. Only the ranking matters, not the magnitude.
    static func scoreElement(_ element: Element) -> Int {
        var score = 0

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

        // Own text only, so a wrapper div does not inherit its children's length.
        let textLength = element.ownText().count
        if textLength > 500 {
            score += 30
        } else if textLength > 100 {
            score += 20
        }

        let directParagraphs = element.children().array().filter { $0.tagName() == "p" }
        score += directParagraphs.count * 10

        // Link density penalty.
        let fullText = (try? element.text()) ?? ""
        let linkText = (try? element.select("a").text()) ?? ""
        if !fullText.isEmpty {
            let linkDensity = Double(linkText.count) / Double(fullText.count)
            if linkDensity > 0.5 {
                score -= 50
            }
        }

        // Commas stand in for sentence count, in both Latin and Japanese punctuation.
        let commaCount = fullText.filter { $0 == "," || $0 == "\u{3001}" }.count
        score += commaCount * 3

        return score
    }

    // MARK: - (C) Markdown Conversion

    /// Walks an element into Markdown, resolving relative links against `baseURL`.
    static func convertToMarkdown(element: Element, baseURL: URL) -> String {
        var lines: [String] = []
        walkNode(element, baseURL: baseURL, lines: &lines, listDepth: 0, listIndex: nil)
        return lines.joined(separator: "\n")
    }

    /// Appends the Markdown for one node and its descendants to `lines`.
    ///
    /// Recursion depth follows DOM depth, with no guard, so pathologically nested markup
    /// can overflow the stack. Unknown elements pass their children through, which is why
    /// custom elements do not swallow their content.
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
            // Neither text nor element (a document or doctype): descend into the children.
            for child in node.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            }
            return
        }

        let tag = element.tagName().lowercased()

        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.last!))!
            let prefix = String(repeating: "#", count: level)
            let text = (try? element.text()) ?? ""
            if !text.isEmpty {
                lines.append("")
                lines.append("\(prefix) \(text)")
                lines.append("")
            }

        case "a":
            let text = (try? element.text()) ?? ""
            let href = resolveURL(try? element.attr("href"), base: baseURL)
            if !text.isEmpty, let href = href {
                lines.append("[\(text)](\(href))")
            } else if !text.isEmpty {
                lines.append(text)
            }

        case "img":
            let alt = (try? element.attr("alt")) ?? ""
            let src = resolveURL(try? element.attr("src"), base: baseURL)
            if let src = src {
                lines.append("![\(alt)](\(src))")
            }

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

        case "code":
            // Inside <pre> this is the block form; the fence is emitted here rather than
            // by the <pre> branch, which delegates to this one.
            if element.parent()?.tagName().lowercased() == "pre" {
                let text = (try? element.text()) ?? ""
                // An empty fence is pure noise, so emit nothing.
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

        case "pre":
            // The <pre><code>…</code></pre> shape: let the <code> branch pick up the language hint.
            if let codeChild = element.children().array().first(where: { $0.tagName() == "code" }) {
                walkNode(codeChild, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            } else {
                let text = (try? element.text()) ?? ""
                // An empty fence is pure noise, so emit nothing.
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                lines.append("")
                lines.append("```")
                lines.append(text)
                lines.append("```")
                lines.append("")
            }

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

        // Reached only when an <li> is walked directly; the ul/ol branches format their own.
        case "li":
            for child in element.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            }

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

        case "table":
            let tableMarkdown = convertTable(element, baseURL: baseURL)
            if !tableMarkdown.isEmpty {
                lines.append("")
                lines.append(tableMarkdown)
                lines.append("")
            }

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

        case "br":
            lines.append("")

        case "hr":
            lines.append("")
            lines.append("---")
            lines.append("")

        // Containers with no Markdown of their own: pass their children through.
        case "div", "section", "article", "main", "span", "figure", "figcaption", "details", "summary":
            for child in element.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            }

        // Table internals are already rendered by the "table" branch; walking them again
        // would duplicate every cell.
        case "thead", "tbody", "tfoot", "tr", "th", "td", "caption", "colgroup", "col":
            break

        default:
            // Unknown or custom element: keep its content, drop the wrapper.
            for child in element.getChildNodes() {
                walkNode(child, baseURL: baseURL, lines: &lines, listDepth: listDepth, listIndex: listIndex)
            }
        }
    }

    /// Renders a table as a GitHub-flavoured Markdown table, or `""` when it has no usable rows.
    ///
    /// Cells are flattened to text, so links, emphasis and images inside a table are lost.
    /// Rowspan and colspan are ignored, which shifts cells left in merged rows.
    private static func convertTable(_ table: Element, baseURL: URL) -> String {
        var headerCells: [String] = []
        var rows: [[String]] = []

        // Header row, preferred source: <thead>.
        if let thead = try? table.select("thead").first() {
            if let tr = try? thead.select("tr").first() {
                headerCells = (try? tr.select("th, td").array().map { (try? $0.text()) ?? "" }) ?? []
            }
        }

        // No <thead>: take the first row, but only if it is made of <th>.
        if headerCells.isEmpty {
            if let firstRow = try? table.select("tr").first() {
                let ths = (try? firstRow.select("th").array()) ?? []
                if !ths.isEmpty {
                    headerCells = ths.map { (try? $0.text()) ?? "" }
                }
            }
        }

        // Body rows.
        let allRows = (try? table.select("tr").array()) ?? []
        let startIndex = headerCells.isEmpty ? 0 : 1
        for i in startIndex..<allRows.count {
            let cells = (try? allRows[i].select("td, th").array().map { (try? $0.text()) ?? "" }) ?? []
            if !cells.isEmpty {
                rows.append(cells)
            }
        }

        // Markdown has no headerless table, so the first data row is promoted.
        if headerCells.isEmpty, !rows.isEmpty {
            headerCells = rows.removeFirst()
        }

        guard !headerCells.isEmpty else { return "" }

        // Pad every row to the widest one; ragged rows break Markdown table rendering.
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

    /// Collects the page metadata worth keeping. Missing tags are simply absent from the result.
    ///
    /// Must run before ``cleanDOM(_:)``, which removes the elements this reads.
    static func extractMetadata(from doc: Document) -> [String: String] {
        var metadata: [String: String] = [:]

        if let ogTitle = try? doc.select("meta[property=og:title]").first()?.attr("content"),
           !ogTitle.isEmpty {
            metadata["og:title"] = ogTitle
        }

        if let desc = try? doc.select("meta[name=description]").first()?.attr("content"),
           !desc.isEmpty {
            metadata["description"] = desc
        }

        if let ogDesc = try? doc.select("meta[property=og:description]").first()?.attr("content"),
           !ogDesc.isEmpty {
            metadata["og:description"] = ogDesc
        }

        if let ogImage = try? doc.select("meta[property=og:image]").first()?.attr("content"),
           !ogImage.isEmpty {
            metadata["og:image"] = ogImage
        }

        if let canonical = try? doc.select("link[rel=canonical]").first()?.attr("href"),
           !canonical.isEmpty {
            metadata["canonical"] = canonical
        }

        return metadata
    }

    /// Returns the page title, preferring `og:title` over `<title>` because it omits the site suffix.
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

    /// Resolves a link against the page URL and strips its tracking parameters.
    ///
    /// Returns `nil` for `data:`, `javascript:` and pure fragment links, which makes the
    /// caller emit the link text alone rather than an unusable Markdown link.
    private static func resolveURL(_ href: String?, base: URL) -> String? {
        guard let href = href, !href.isEmpty else { return nil }
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

    /// Drops tracking query parameters so links cost fewer tokens and compare equal across sources.
    ///
    /// Removes anything starting with `utm_` plus a fixed list of vendor click ids. Other
    /// parameters are kept, since they may select the page.
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

    /// Tidies generated Markdown: removes base64 data URIs, trailing whitespace, repeated
    /// blank lines and consecutive duplicate lines.
    ///
    /// The duplicate-line pass spares table rows, so a table with two identical rows keeps both.
    static func postProcess(_ markdown: String) -> String {
        // A base64 blob is pure token waste to an LLM, and these run to megabytes.
        let deDataURI = markdown.replacingOccurrences(
            of: "data:[^;\\s]+;base64,[A-Za-z0-9+/=]{100,}",
            with: "[data-uri removed]",
            options: .regularExpression
        )
        let lines = deDataURI.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }

        // Collapse blank runs to one, and fold consecutive identical lines into one.
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
            // A line identical to the one before it is duplication noise — except in a
            // table, where identical rows are data.
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
