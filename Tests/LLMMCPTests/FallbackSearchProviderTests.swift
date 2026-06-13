import Testing
@testable import LLMMCP

// MARK: - Test Data

private let sampleResults = [
    WebSearchResult(title: "Result 1", url: "https://example.com/1", snippet: "Snippet 1"),
]

private let fallbackResults = [
    WebSearchResult(title: "Fallback 1", url: "https://fallback.com/1", snippet: "Fallback snippet"),
]

// MARK: - FallbackSearchProvider Tests

@Suite("FallbackSearchProvider Tests")
struct FallbackSearchProviderTests {
    @Test("Returns results from primary provider")
    func primarySuccess() async throws {
        let primary = MockSearchProvider(behavior: .success(sampleResults))
        let fallback = MockSearchProvider(behavior: .success(fallbackResults))
        let provider = FallbackSearchProvider(providers: [primary, fallback])

        let results = try await provider.search(query: "test", maxResults: 5)
        #expect(results.count == 1)
        #expect(results[0].title == "Result 1")
        #expect(primary.callCount == 1)
        #expect(fallback.callCount == 0)
    }

    @Test("Falls back on primary failure")
    func primaryFailureFallback() async throws {
        let primary = MockSearchProvider(behavior: .failure(WebSearchError.httpError(statusCode: 500)))
        let fallback = MockSearchProvider(behavior: .success(fallbackResults))
        let provider = FallbackSearchProvider(providers: [primary, fallback])

        let results = try await provider.search(query: "test", maxResults: 5)
        #expect(results.count == 1)
        #expect(results[0].title == "Fallback 1")
        #expect(primary.callCount == 1)
        #expect(fallback.callCount == 1)
    }

    @Test("Falls back on primary empty results")
    func primaryEmptyFallback() async throws {
        let primary = MockSearchProvider(behavior: .empty)
        let fallback = MockSearchProvider(behavior: .success(fallbackResults))
        let provider = FallbackSearchProvider(providers: [primary, fallback])

        let results = try await provider.search(query: "test", maxResults: 5)
        #expect(results.count == 1)
        #expect(results[0].title == "Fallback 1")
    }

    @Test("Throws allProvidersFailed when all fail")
    func allProvidersFail() async {
        let primary = MockSearchProvider(behavior: .failure(WebSearchError.httpError(statusCode: 500)))
        let fallback = MockSearchProvider(behavior: .failure(WebSearchError.httpError(statusCode: 503)))
        let provider = FallbackSearchProvider(providers: [primary, fallback])

        do {
            _ = try await provider.search(query: "test", maxResults: 5)
            #expect(Bool(false), "Should have thrown")
        } catch let error as WebSearchError {
            if case .allProvidersFailed(let errors) = error {
                #expect(errors.count == 2)
            } else {
                #expect(Bool(false), "Expected allProvidersFailed error")
            }
        } catch {
            #expect(Bool(false), "Expected WebSearchError")
        }
    }

    @Test("UnconfiguredSearchProvider throws providerNotConfigured")
    func unconfiguredProvider() async {
        let provider = UnconfiguredSearchProvider()
        do {
            _ = try await provider.search(query: "test", maxResults: 5)
            #expect(Bool(false), "Should have thrown")
        } catch let error as WebSearchError {
            if case .providerNotConfigured = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected providerNotConfigured error")
            }
        } catch {
            #expect(Bool(false), "Expected WebSearchError")
        }
    }
}
