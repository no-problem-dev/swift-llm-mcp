import Foundation

// MARK: - DocCSupport

/// Maps a DocC documentation page URL to the render JSON that actually contains its text.
///
/// Apple and Swift DocC sites serve an empty JavaScript shell as HTML, so fetching the page
/// URL yields nothing readable; the same content is available as JSON at a parallel path.
enum DocCSupport {

    /// Returns the render JSON URL for a DocC page, or `nil` for any other URL.
    ///
    /// Only `developer.apple.com` and `docs.swift.org` are recognised — a DocC site hosted
    /// anywhere else, including GitHub Pages, falls through to the ordinary HTML path.
    static func renderJSONURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path

        // developer.apple.com/documentation/... -> /tutorials/data/documentation/....json
        if host == "developer.apple.com" {
            guard path.hasPrefix("/documentation/") || path.hasPrefix("/tutorials/") else { return nil }
            // A data JSON URL is already the raw form; leave it to the ordinary fetch path.
            if path.hasPrefix("/tutorials/data/") { return nil }
            let trimmed = trimSlash(path)
            return URL(string: "https://developer.apple.com/tutorials/data\(trimmed).json")
        }

        // docs.swift.org/<bundle>/documentation/... -> /<bundle>/data/documentation/....json
        if host == "docs.swift.org" {
            let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard comps.count >= 2, comps[1] == "documentation" else { return nil }
            let bundle = comps[0]
            let rest = comps.dropFirst().joined(separator: "/")  // documentation/...
            let trimmed = trimSlash("/\(rest)")
            return URL(string: "https://docs.swift.org/\(bundle)/data\(trimmed).json")
        }

        return nil
    }

    private static func trimSlash(_ s: String) -> String {
        var t = s
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }
}

// MARK: - DocCRenderer

/// Converts DocC render JSON into readable Markdown.
enum DocCRenderer {

    /// Renders the JSON, or returns `nil` when it will not parse or produces no text.
    ///
    /// Covers the abstract, the declaration, the content blocks and the topic list. Node
    /// types outside that set — `mentions`, `seeAlsoSections`, relationships — are dropped
    /// silently, so the Markdown is a readable subset rather than a faithful transcription.
    ///
    /// - Parameters:
    ///   - jsonData: A DocC render JSON document.
    ///   - host: Host used to turn the document's relative reference URLs absolute.
    static func render(jsonData: Data, host: String) -> (title: String?, markdown: String)? {
        guard let root = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            return nil
        }
        let refs = root["references"] as? [String: Any] ?? [:]
        var lines: [String] = []

        // Title and role heading ("Instance Method", "Structure", ...).
        let metadata = root["metadata"] as? [String: Any]
        let title = metadata?["title"] as? String
        if let title { lines.append("# \(title)") }
        if let role = metadata?["roleHeading"] as? String, !role.isEmpty {
            lines.append("*\(role)*")
        }

        // Abstract: the one-line summary.
        if let abstract = root["abstract"] as? [[String: Any]] {
            let text = renderInline(abstract, refs: refs, host: host)
            if !text.isEmpty { lines.append("\n\(text)") }
        }

        // Primary content: the declaration and the discussion.
        if let sections = root["primaryContentSections"] as? [[String: Any]] {
            for section in sections {
                switch section["kind"] as? String {
                case "declarations":
                    if let decls = section["declarations"] as? [[String: Any]] {
                        for decl in decls {
                            let tokens = (decl["tokens"] as? [[String: Any]] ?? [])
                                .compactMap { $0["text"] as? String }.joined()
                            if !tokens.isEmpty {
                                let lang = (decl["languages"] as? [String])?.first ?? "swift"
                                lines.append("\n```\(lang)\n\(tokens)\n```")
                            }
                        }
                    }
                case "content":
                    if let content = section["content"] as? [[String: Any]] {
                        lines.append(contentsOf: renderBlocks(content, refs: refs, host: host))
                    }
                default:
                    break  // Skip section kinds such as "mentions".
                }
            }
        }

        // Topic sections: the links to child symbols.
        if let topics = root["topicSections"] as? [[String: Any]], !topics.isEmpty {
            lines.append("\n## Topics")
            for topic in topics {
                if let t = topic["title"] as? String { lines.append("\n### \(t)") }
                for id in (topic["identifiers"] as? [String] ?? []) {
                    if let ref = refs[id] as? [String: Any], let t = ref["title"] as? String {
                        let url = (ref["url"] as? String).map { absolutize($0, host: host) }
                        let abstract = (ref["abstract"] as? [[String: Any]]).map { renderInline($0, refs: refs, host: host) } ?? ""
                        let link = url.map { "[\(t)](\($0))" } ?? t
                        lines.append(abstract.isEmpty ? "- \(link)" : "- \(link) — \(abstract)")
                    }
                }
            }
        }

        let markdown = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }
        return (title, markdown)
    }

    // MARK: - Block / Inline rendering

    private static func renderBlocks(_ nodes: [[String: Any]], refs: [String: Any], host: String) -> [String] {
        var out: [String] = []
        for node in nodes {
            switch node["type"] as? String {
            case "heading":
                let level = min(6, max(2, (node["level"] as? Int) ?? 2))
                if let text = node["text"] as? String {
                    out.append("\n\(String(repeating: "#", count: level)) \(text)")
                }
            case "paragraph":
                let text = renderInline(node["inlineContent"] as? [[String: Any]] ?? [], refs: refs, host: host)
                if !text.isEmpty { out.append("\n\(text)") }
            case "codeListing":
                let syntax = node["syntax"] as? String ?? ""
                let code = (node["code"] as? [String] ?? []).joined(separator: "\n")
                if !code.isEmpty { out.append("\n```\(syntax)\n\(code)\n```") }
            case "aside":
                let name = (node["name"] as? String) ?? (node["style"] as? String)?.capitalized ?? "Note"
                let inner = renderBlocks(node["content"] as? [[String: Any]] ?? [], refs: refs, host: host)
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                let quoted = inner.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
                out.append("\n> **\(name)**\n\(quoted)")
            case "unorderedList":
                for item in (node["items"] as? [[String: Any]] ?? []) {
                    let text = renderBlocks(item["content"] as? [[String: Any]] ?? [], refs: refs, host: host)
                        .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { out.append("- \(text)") }
                }
            case "orderedList":
                for (i, item) in (node["items"] as? [[String: Any]] ?? []).enumerated() {
                    let text = renderBlocks(item["content"] as? [[String: Any]] ?? [], refs: refs, host: host)
                        .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { out.append("\(i + 1). \(text)") }
                }
            default:
                break
            }
        }
        return out
    }

    private static func renderInline(_ nodes: [[String: Any]], refs: [String: Any], host: String) -> String {
        nodes.map { node -> String in
            switch node["type"] as? String {
            case "text":
                return node["text"] as? String ?? ""
            case "codeVoice":
                let code = node["code"] as? String ?? ""
                return code.isEmpty ? "" : "`\(code)`"
            case "reference":
                let id = node["identifier"] as? String ?? ""
                guard let ref = refs[id] as? [String: Any], let t = ref["title"] as? String else { return "" }
                if let u = ref["url"] as? String { return "[\(t)](\(absolutize(u, host: host)))" }
                return t
            case "emphasis":
                return "*\(renderInline(node["inlineContent"] as? [[String: Any]] ?? [], refs: refs, host: host))*"
            case "strong":
                return "**\(renderInline(node["inlineContent"] as? [[String: Any]] ?? [], refs: refs, host: host))**"
            case "link":
                let t = node["title"] as? String ?? ""
                if let d = node["destination"] as? String { return "[\(t)](\(d))" }
                return t
            default:
                return ""
            }
        }.joined()
    }

    private static func absolutize(_ url: String, host: String) -> String {
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        return "https://\(host)\(url)"
    }
}
