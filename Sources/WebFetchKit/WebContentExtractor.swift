import Foundation

// MARK: - WebContentExtractor Protocol

/// Strategy for turning a page of HTML into the text worth reading.
///
/// Conform to it when the built-in readability heuristic picks the wrong element on a site
/// you care about, then pass your type to ``WebFetchEngine/init(allowedDomains:timeout:maxContentSize:extractor:transport:)``.
/// ``SwiftSoupContentExtractor`` is the default.
///
/// ```swift
/// let extractor = SwiftSoupContentExtractor()
/// let content = try extractor.extract(html: htmlString, url: pageURL)
/// print(content.content) // Markdown
/// ```
public protocol WebContentExtractor: Sendable {
    /// Extracts the main content of a page as Markdown.
    ///
    /// Implementations are expected to return something rather than throw on a thin page —
    /// ``WebFetchEngine`` treats a throw here as a failed fetch.
    ///
    /// - Parameters:
    ///   - html: Raw HTML source.
    ///   - url: The page URL, used to resolve relative links to absolute ones.
    func extract(html: String, url: URL) throws -> ExtractedContent
}

// MARK: - ExtractedContent

/// What a ``WebContentExtractor`` found on a page.
public struct ExtractedContent: Sendable {
    public let title: String?

    /// The main content, in Markdown.
    public let content: String

    /// Page metadata, keyed by its HTML name: `description`, `og:title`, `og:description`,
    /// `og:image`, `canonical`. Absent keys mean the page did not declare them.
    public let metadata: [String: String]

    public init(title: String?, content: String, metadata: [String: String] = [:]) {
        self.title = title
        self.content = content
        self.metadata = metadata
    }
}
