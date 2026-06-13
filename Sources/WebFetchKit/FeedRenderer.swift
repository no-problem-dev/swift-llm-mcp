import Foundation
import SwiftSoup
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - FeedSupport

/// RSS/Atom フィードの検出。
enum FeedSupport {
    static func isFeed(contentType: String?, content: String) -> Bool {
        if let ct = contentType?.lowercased() {
            if ct.contains("application/rss+xml") || ct.contains("application/atom+xml") {
                return true
            }
        }
        // 先頭付近に <rss / <feed があれば feed とみなす（XML 宣言は無視）
        let head = content.prefix(1024).lowercased()
        return head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:rdf")
    }
}

// MARK: - FeedRenderer

/// RSS/Atom XML を item 一覧の Markdown に整形する（生 XML の冗長トークンを削減）。
enum FeedRenderer {

    static func render(xml content: String, maxItems: Int = 50) -> (title: String?, markdown: String)? {
        guard let data = content.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        let delegate = FeedParserDelegate()
        parser.delegate = delegate
        guard parser.parse(), !delegate.items.isEmpty else { return nil }

        var lines: [String] = []
        if let t = delegate.feedTitle?.trimmed, !t.isEmpty { lines.append("# \(t)") }

        for item in delegate.items.prefix(maxItems) {
            let title = item.title?.trimmed ?? "(no title)"
            lines.append("\n## \(title)")
            var meta: [String] = []
            if let date = item.date?.trimmed, !date.isEmpty { meta.append(date) }
            if let link = item.link?.trimmed, !link.isEmpty { meta.append(link) }
            if !meta.isEmpty { lines.append(meta.joined(separator: " — ")) }
            if let summary = item.summary?.trimmed, !summary.isEmpty {
                lines.append("\n\(plainText(summary))")
            }
        }

        let markdown = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }
        return (delegate.feedTitle?.trimmed, markdown)
    }

    /// description/summary に含まれる HTML を素のテキストに落とし、長すぎる場合は切り詰める。
    private static func plainText(_ html: String, limit: Int = 500) -> String {
        let text = (try? SwiftSoup.parse(html).text()) ?? html
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

// MARK: - XMLParserDelegate

private final class FeedParserDelegate: NSObject, XMLParserDelegate {
    struct Item {
        var title: String?
        var link: String?
        var date: String?
        var summary: String?
    }

    var feedTitle: String?
    var items: [Item] = []

    private var inItem = false
    private var current = Item()
    private var buffer = ""
    private var currentElement = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = elementName.lowercased()
        currentElement = name
        buffer = ""

        if name == "item" || name == "entry" {
            inItem = true
            current = Item()
        }
        // Atom の <link href="..."> は属性にURLがある
        if name == "link", inItem, current.link == nil, let href = attributes["href"], !href.isEmpty {
            current.link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { buffer += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if name == "item" || name == "entry" {
            items.append(current)
            inItem = false
        } else if inItem {
            switch name {
            case "title": if current.title == nil { current.title = value }
            case "link": if current.link == nil, !value.isEmpty { current.link = value }
            case "pubdate", "published", "updated", "date", "dc:date":
                if current.date == nil { current.date = value }
            case "description", "summary", "content", "content:encoded":
                if current.summary == nil, !value.isEmpty { current.summary = value }
            default: break
            }
        } else {
            // フィード全体のタイトル（最初の <title> のみ）
            if name == "title", feedTitle == nil, !value.isEmpty { feedTitle = value }
        }
        buffer = ""
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
