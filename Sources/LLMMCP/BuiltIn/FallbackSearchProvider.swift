import Foundation

// MARK: - FallbackSearchProvider

/// 複数プロバイダーの自動フォールバックチェーン
///
/// プロバイダーを順番に試行し、最初に成功した結果を返します。
/// 空結果も失敗として扱い、次のプロバイダーに進みます。
///
/// ## 使用例
///
/// ```swift
/// let provider = FallbackSearchProvider(providers: [
///     BraveSearchProvider(apiKey: "BRAVE_KEY"),
///     SerperSearchProvider(apiKey: "SERPER_KEY")
/// ])
/// let results = try await provider.search(query: "Swift", maxResults: 5)
/// ```
public final class FallbackSearchProvider: WebSearchProvider, @unchecked Sendable {
    // MARK: - Properties

    private let providers: [any WebSearchProvider]

    // MARK: - Initialization

    /// FallbackSearchProviderを作成
    ///
    /// - Parameter providers: 試行順のプロバイダー配列
    public init(providers: [any WebSearchProvider]) {
        self.providers = providers
    }

    // MARK: - WebSearchProvider

    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        var errors: [Error] = []

        for provider in providers {
            do {
                let results = try await provider.search(query: query, maxResults: maxResults)
                if !results.isEmpty {
                    return results
                }
                // Empty results — try next provider
                errors.append(WebSearchError.noResults)
            } catch {
                errors.append(error)
            }
        }

        throw WebSearchError.allProvidersFailed(errors)
    }
}
