import Foundation

// MARK: - DocCSupport

/// Apple/Swift の DocC ドキュメントは HTML が JS 描画シェルで本文を持たないが、
/// 同じ内容を render JSON API で配信している。DocC ページ URL を検出し、対応する
/// JSON URL に変換する。
enum DocCSupport {

    /// DocC ドキュメントページなら、その render JSON の URL を返す。DocC でなければ nil。
    static func renderJSONURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path

        // developer.apple.com/documentation/... → /tutorials/data/documentation/....json
        if host == "developer.apple.com" {
            guard path.hasPrefix("/documentation/") || path.hasPrefix("/tutorials/") else { return nil }
            // すでに data JSON ならそのまま対象外（生 JSON は通常 fetch で扱う）
            if path.hasPrefix("/tutorials/data/") { return nil }
            let trimmed = trimSlash(path)
            return URL(string: "https://developer.apple.com/tutorials/data\(trimmed).json")
        }

        // docs.swift.org/<bundle>/documentation/... → /<bundle>/data/documentation/....json
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

/// DocC render JSON を読みやすい Markdown に変換する。
enum DocCRenderer {

    /// render JSON データを Markdown 化する。失敗・空なら nil。
    /// - Parameter host: 参照 URL を絶対化するためのホスト（例: developer.apple.com）
    static func render(jsonData: Data, host: String) -> (title: String?, markdown: String)? {
        guard let root = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            return nil
        }
        let refs = root["references"] as? [String: Any] ?? [:]
        var lines: [String] = []

        // タイトル + 種別
        let metadata = root["metadata"] as? [String: Any]
        let title = metadata?["title"] as? String
        if let title { lines.append("# \(title)") }
        if let role = metadata?["roleHeading"] as? String, !role.isEmpty {
            lines.append("*\(role)*")
        }

        // abstract（概要）
        if let abstract = root["abstract"] as? [[String: Any]] {
            let text = renderInline(abstract, refs: refs, host: host)
            if !text.isEmpty { lines.append("\n\(text)") }
        }

        // primaryContentSections（宣言 + 本文）
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
                    break  // mentions 等はスキップ
                }
            }
        }

        // topicSections（子トピックへのリンク一覧）
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
