import Testing
@testable import LLMMCP

// MARK: - MockSearchProvider

/// テスト用のモック検索プロバイダー
final class MockSearchProvider: WebSearchProvider, @unchecked Sendable {
    enum Behavior: Sendable {
        case success([WebSearchResult])
        case empty
        case failure(Error)
    }

    private var behavior: Behavior
    private(set) var callCount = 0

    init(behavior: Behavior = .empty) {
        self.behavior = behavior
    }

    func setBehavior(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        callCount += 1
        switch behavior {
        case .success(let results):
            return Array(results.prefix(maxResults))
        case .empty:
            return []
        case .failure(let error):
            throw error
        }
    }
}

// MARK: - Test Data

private let sampleResults = [
    WebSearchResult(title: "Result 1", url: "https://example.com/1", snippet: "Snippet 1"),
    WebSearchResult(title: "Result 2", url: "https://example.com/2", snippet: "Snippet 2"),
    WebSearchResult(title: "Result 3", url: "https://example.com/3", snippet: "Snippet 3"),
]

// MARK: - RateLimiter Tests

@Suite("RateLimiter Tests")
struct RateLimiterTests {
    @Test("Acquires immediately when tokens available")
    func acquireImmediate() async {
        let limiter = RateLimiter(maxRequestsPerSecond: 10)
        // Should not block significantly
        await limiter.acquire()
    }

    @Test("Throttles when tokens exhausted")
    func throttling() async {
        let limiter = RateLimiter(maxRequestsPerSecond: 2)

        let start = ContinuousClock.now
        // Exhaust tokens
        await limiter.acquire()
        await limiter.acquire()
        // This should be delayed
        await limiter.acquire()
        let elapsed = ContinuousClock.now - start

        let elapsedMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        // Should have waited at least some time for the third acquire
        #expect(elapsedMs > 100)
    }
}

// MARK: - CircuitBreaker Tests

@Suite("CircuitBreaker Tests")
struct CircuitBreakerTests {
    @Test("Starts in closed state")
    func initialState() async {
        let cb = CircuitBreaker(failureThreshold: 3, resetTimeout: 60)
        let state = await cb.state
        #expect(state == .closed)
    }

    @Test("Stays closed under threshold")
    func belowThreshold() async {
        let cb = CircuitBreaker(failureThreshold: 3, resetTimeout: 60)
        await cb.recordFailure()
        await cb.recordFailure()
        let state = await cb.state
        #expect(state == .closed)
        let canExecute = await cb.requestExecution()
        #expect(canExecute == true)
    }

    @Test("Opens at failure threshold")
    func opensAtThreshold() async {
        let cb = CircuitBreaker(failureThreshold: 3, resetTimeout: 60)
        await cb.recordFailure()
        await cb.recordFailure()
        await cb.recordFailure()
        let state = await cb.state
        #expect(state == .open)
        let canExecute = await cb.requestExecution()
        #expect(canExecute == false)
    }

    @Test("Resets on success")
    func resetsOnSuccess() async {
        let cb = CircuitBreaker(failureThreshold: 3, resetTimeout: 60)
        await cb.recordFailure()
        await cb.recordFailure()
        await cb.recordSuccess()
        let state = await cb.state
        #expect(state == .closed)
    }

    @Test("Transitions to halfOpen after timeout")
    func halfOpenTransition() async {
        let cb = CircuitBreaker(failureThreshold: 1, resetTimeout: 0.1)
        await cb.recordFailure()
        let stateAfterFailure = await cb.state
        #expect(stateAfterFailure == .open)

        // Wait for reset timeout
        try? await Task.sleep(for: .milliseconds(150))

        let canExecute = await cb.requestExecution()
        #expect(canExecute == true)
        let stateAfterTimeout = await cb.state
        #expect(stateAfterTimeout == .halfOpen)
    }
}

// MARK: - SearchResultCache Tests

@Suite("SearchResultCache Tests")
struct SearchResultCacheTests {
    @Test("Cache hit returns results")
    func cacheHit() async {
        let cache = SearchResultCache(ttl: 60, maxEntries: 10)
        await cache.set(sampleResults, query: "swift", maxResults: 5)

        let result = await cache.get(query: "swift", maxResults: 5)
        #expect(result != nil)
        #expect(result?.count == 3)
    }

    @Test("Cache miss returns nil")
    func cacheMiss() async {
        let cache = SearchResultCache(ttl: 60, maxEntries: 10)
        let result = await cache.get(query: "nonexistent", maxResults: 5)
        #expect(result == nil)
    }

    @Test("Different maxResults are separate entries")
    func differentMaxResults() async {
        let cache = SearchResultCache(ttl: 60, maxEntries: 10)
        await cache.set(sampleResults, query: "swift", maxResults: 5)

        let result = await cache.get(query: "swift", maxResults: 3)
        #expect(result == nil)
    }

    @Test("TTL expiration")
    func ttlExpiration() async {
        let cache = SearchResultCache(ttl: 0.1, maxEntries: 10)
        await cache.set(sampleResults, query: "swift", maxResults: 5)

        try? await Task.sleep(for: .milliseconds(150))

        let result = await cache.get(query: "swift", maxResults: 5)
        #expect(result == nil)
    }

    @Test("LRU eviction")
    func lruEviction() async {
        let cache = SearchResultCache(ttl: 60, maxEntries: 2)

        await cache.set(sampleResults, query: "first", maxResults: 5)
        await cache.set(sampleResults, query: "second", maxResults: 5)
        // This should evict "first"
        await cache.set(sampleResults, query: "third", maxResults: 5)

        let first = await cache.get(query: "first", maxResults: 5)
        let second = await cache.get(query: "second", maxResults: 5)
        let third = await cache.get(query: "third", maxResults: 5)

        #expect(first == nil)
        #expect(second != nil)
        #expect(third != nil)
    }

    @Test("Clear removes all entries")
    func clearCache() async {
        let cache = SearchResultCache(ttl: 60, maxEntries: 10)
        await cache.set(sampleResults, query: "swift", maxResults: 5)
        await cache.clear()

        let count = await cache.count
        #expect(count == 0)
    }
}

// MARK: - ResilientSearchProvider Tests

@Suite("ResilientSearchProvider Tests")
struct ResilientSearchProviderTests {
    @Test("Successful search returns results")
    func successfulSearch() async throws {
        let mock = MockSearchProvider(behavior: .success(sampleResults))
        let resilient = ResilientSearchProvider(
            provider: mock,
            configuration: SearchResilienceConfiguration(maxRequestsPerSecond: 100, maxRetries: 0)
        )

        let results = try await resilient.search(query: "swift", maxResults: 5)
        #expect(results.count == 3)
        #expect(mock.callCount == 1)
    }

    @Test("Caches results on success")
    func cachesResults() async throws {
        let mock = MockSearchProvider(behavior: .success(sampleResults))
        let resilient = ResilientSearchProvider(
            provider: mock,
            configuration: SearchResilienceConfiguration(maxRequestsPerSecond: 100, maxRetries: 0)
        )

        _ = try await resilient.search(query: "swift", maxResults: 5)
        let results = try await resilient.search(query: "swift", maxResults: 5)
        #expect(results.count == 3)
        #expect(mock.callCount == 1) // Second call served from cache
    }

    @Test("Retries on failure")
    func retriesOnFailure() async {
        let mock = MockSearchProvider(behavior: .failure(WebSearchError.httpError(statusCode: 500)))
        let resilient = ResilientSearchProvider(
            provider: mock,
            configuration: SearchResilienceConfiguration(
                maxRequestsPerSecond: 100,
                failureThreshold: 10,
                maxRetries: 2
            )
        )

        do {
            _ = try await resilient.search(query: "swift", maxResults: 5)
            #expect(Bool(false), "Should have thrown")
        } catch {
            // 1 initial + 2 retries = 3 calls
            #expect(mock.callCount == 3)
        }
    }
}
