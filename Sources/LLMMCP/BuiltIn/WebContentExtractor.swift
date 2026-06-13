import Foundation

// MARK: - WebContentExtractor Protocol

/// HTMLコンテンツ抽出プロバイダーのプロトコル
///
/// 異なる抽出戦略を差し替え可能にするための抽象化です。
/// `WebSearchProvider` パターンに倣い、デフォルト実装として
/// `SwiftSoupContentExtractor` を提供します。
///
/// ## 使用例
///
/// ```swift
/// let extractor = SwiftSoupContentExtractor()
/// let content = try await extractor.extract(html: htmlString, url: pageURL)
/// print(content.content) // Markdown形式のテキスト
/// ```
public protocol WebContentExtractor: Sendable {
    /// HTMLからコンテンツを抽出
    ///
    /// - Parameters:
    ///   - html: 生のHTML文字列
    ///   - url: ページのURL（相対リンクの解決に使用）
    /// - Returns: 抽出されたコンテンツ
    func extract(html: String, url: URL) throws -> ExtractedContent
}

// MARK: - ExtractedContent

/// 抽出されたWebコンテンツ
public struct ExtractedContent: Sendable {
    /// ページタイトル
    public let title: String?

    /// 抽出されたコンテンツ（Markdown形式）
    public let content: String

    /// メタデータ（description, og:image, canonical等）
    public let metadata: [String: String]

    public init(title: String?, content: String, metadata: [String: String] = [:]) {
        self.title = title
        self.content = content
        self.metadata = metadata
    }
}
