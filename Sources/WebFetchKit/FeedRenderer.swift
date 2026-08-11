import Foundation
import SwiftSoup
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
// On Linux the XML parser ships as a module of its own rather than as part of
// Foundation, so `XMLParser` and `XMLParserDelegate` are only in scope once this
// is imported.
import FoundationXML
#endif

// MARK: - FeedSupport

/// Recognises RSS, Atom and RDF feeds.
enum FeedSupport {
    /// Reports a feed from the Content-Type, or from a root element found in the first 1 KB.
    static func isFeed(contentType: String?, content: String) -> Bool {
        if let ct = contentType?.lowercased() {
            if ct.contains("application/rss+xml") || ct.contains("application/atom+xml") {
                return true
            }
        }
        // Sniff the root element, skipping past any XML declaration and doctype.
        let head = content.prefix(1024).lowercased()
        return head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:rdf")
    }
}

// MARK: - FeedRenderer

/// Reshapes RSS and Atom XML into a Markdown item list, which costs far fewer tokens than the raw XML.
enum FeedRenderer {

    /// Renders a feed, or returns `nil` when the XML will not parse or holds no items.
    ///
    /// Returning `nil` is how a caller learns to fall back to another representation.
    /// Items past `maxItems` are dropped without a marker, and each item's summary is cut
    /// to 500 characters, so the output is a preview rather than the full feed.
    ///
    /// - Parameters:
    ///   - content: The feed XML. It must be UTF-8-encodable.
    ///   - maxItems: How many items to render.
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

    /// Flattens the HTML inside a description or summary to plain text and cuts it at `limit` characters.
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
        // Atom puts the URL in an attribute: <link href="...">, with no character content.
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
            // The feed's own title: the first <title> outside any item wins.
            if name == "title", feedTitle == nil, !value.isEmpty { feedTitle = value }
        }
        buffer = ""
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
