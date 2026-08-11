import Foundation

// MARK: - FallbackSearchProvider

/// Tries several search backends in order and returns the first non-empty result.
///
/// An empty result counts as a failure, not as "nothing matched", so a provider that
/// legitimately finds nothing hands the query on to the next one. That is what makes this
/// useful across engines with different coverage, and also why it costs one request per
/// provider on a query nothing matches.
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

    /// Creates a chain.
    ///
    /// - Parameter providers: Tried in array order. An empty array makes every search throw
    ///   ``WebSearchError/allProvidersFailed(_:)`` with no underlying errors.
    public init(providers: [any WebSearchProvider]) {
        self.providers = providers
    }

    // MARK: - WebSearchProvider

    /// Returns the first non-empty result, trying each provider in turn.
    ///
    /// Providers are tried sequentially, so the worst case is the sum of every provider's
    /// latency and there is no overall deadline.
    ///
    /// - Throws: ``WebSearchError/allProvidersFailed(_:)``, carrying one error per provider
    ///   in the order they were tried. A provider that returned an empty list contributes
    ///   ``WebSearchError/noResults``.
    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        var errors: [Error] = []

        for provider in providers {
            do {
                let results = try await provider.search(query: query, maxResults: maxResults)
                if !results.isEmpty {
                    return results
                }
                // Empty is treated as failure so the next engine gets a chance.
                errors.append(WebSearchError.noResults)
            } catch {
                errors.append(error)
            }
        }

        throw WebSearchError.allProvidersFailed(errors)
    }
}
