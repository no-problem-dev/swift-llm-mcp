import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - SearchResilienceConfiguration

/// Tuning for ``ResilientSearchProvider``: rate limit, circuit breaker, cache and retries.
public struct SearchResilienceConfiguration: Sendable {
    /// Token refill rate, in requests per second. Also the bucket capacity, with a floor of 1.
    public let maxRequestsPerSecond: Double

    /// Consecutive failures that open the circuit. Each retry attempt counts separately, so
    /// one search using every attempt contributes more than one failure.
    public let failureThreshold: Int

    /// Seconds an open circuit stays open before it will admit a trial request.
    public let resetTimeout: TimeInterval

    /// Seconds a cached result stays valid.
    public let cacheTTL: TimeInterval

    /// Cache capacity. Reaching it evicts the least recently used entry, so the cache is bounded.
    public let maxCacheEntries: Int

    /// Retries after the first attempt. `1` means two attempts in total; `0` disables retrying.
    public let maxRetries: Int

    /// One request per second, circuit opens at 5 failures for 60 seconds, 100 cached
    /// results for 5 minutes, one retry.
    public static let `default` = SearchResilienceConfiguration(
        maxRequestsPerSecond: 1.0,
        failureThreshold: 5,
        resetTimeout: 60,
        cacheTTL: 300,
        maxCacheEntries: 100,
        maxRetries: 1
    )

    public init(
        maxRequestsPerSecond: Double = 1.0,
        failureThreshold: Int = 5,
        resetTimeout: TimeInterval = 60,
        cacheTTL: TimeInterval = 300,
        maxCacheEntries: Int = 100,
        maxRetries: Int = 1
    ) {
        self.maxRequestsPerSecond = maxRequestsPerSecond
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
        self.cacheTTL = cacheTTL
        self.maxCacheEntries = maxCacheEntries
        self.maxRetries = maxRetries
    }
}

// MARK: - RateLimiter

/// A token bucket that paces requests by sleeping, never by throwing.
///
/// Tokens refill continuously at `maxRequestsPerSecond` and the bucket holds at most that
/// many, with a floor of one, so a burst up to the capacity goes through immediately and
/// the rest is spread out.
///
/// It is a pacer, not a hard limit. The actor is released while a caller sleeps, so several
/// concurrent callers can each observe an empty bucket, each wait, and then all proceed —
/// the rate is respected on average but can be exceeded at any instant.
public actor RateLimiter {
    private let maxTokens: Double
    private let refillRate: Double // tokens per second
    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant

    /// Creates a limiter with a full bucket, so the first requests are not delayed.
    ///
    /// - Parameter maxRequestsPerSecond: Refill rate. Values below 1 still give a bucket of
    ///   1 token, so one request always passes immediately after a quiet period.
    public init(maxRequestsPerSecond: Double) {
        self.maxTokens = max(maxRequestsPerSecond, 1.0)
        self.refillRate = maxRequestsPerSecond
        self.tokens = maxTokens
        self.lastRefill = .now
    }

    /// Takes one token, sleeping first if the bucket is empty.
    ///
    /// The wait is bounded by one refill interval — `1 / maxRequestsPerSecond` seconds — so
    /// this never blocks indefinitely and never throws.
    ///
    /// Cancellation returns early **and grants the request anyway**, without consuming a
    /// token. A cancelled caller that goes on to make its request is unpaced, so callers
    /// that care must check `Task.isCancelled` themselves.
    public func acquire() async {
        refillTokens()

        if tokens >= 1.0 {
            tokens -= 1.0
            return
        }

        // Sleep just long enough for the bucket to reach one token.
        let waitTime = (1.0 - tokens) / refillRate
        do {
            try await Task.sleep(for: .milliseconds(Int(waitTime * 1000)))
        } catch {
            // Cancelled. Returning here lets the caller decide what to do.
            return
        }
        refillTokens()
        tokens = max(tokens - 1.0, 0)
    }

    /// Credits tokens for the time since the last refill, capped at the bucket size.
    private func refillTokens() {
        let now = ContinuousClock.Instant.now
        let elapsed = now - lastRefill
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(maxTokens, tokens + elapsedSeconds * refillRate)
        lastRefill = now
    }
}

// MARK: - CircuitBreaker

/// Stops calling a provider that keeps failing, and lets it back in after a cooling-off period.
///
/// The failure count is consecutive: any success resets it to zero, so intermittent errors
/// never accumulate to the threshold.
public actor CircuitBreaker {
    /// Where the breaker is in its cycle.
    public enum State: Sendable {
        /// Everything passes.
        case closed
        /// Nothing passes until `resetTimeout` has elapsed since the last failure.
        case open
        /// Trial period. Requests pass, and the next result decides: success closes the
        /// breaker, failure reopens it. Nothing limits how many requests pass here, so
        /// concurrent callers all get through at once.
        case halfOpen
    }

    private let failureThreshold: Int
    private let resetTimeout: TimeInterval
    private var failureCount: Int = 0
    private var lastFailureTime: ContinuousClock.Instant?
    private(set) public var state: State = .closed

    /// Creates a closed breaker.
    ///
    /// - Parameters:
    ///   - failureThreshold: Consecutive failures that open the breaker.
    ///   - resetTimeout: Seconds after the last failure before a trial request is admitted.
    public init(failureThreshold: Int, resetTimeout: TimeInterval) {
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
    }

    /// Asks whether a request may proceed, moving the breaker to half-open when the timeout has passed.
    ///
    /// Not a pure query — calling it is what ends the open period. `false` is the only
    /// answer that blocks anything, and it comes only from an open breaker whose timeout
    /// has not yet elapsed.
    public func requestExecution() -> Bool {
        switch state {
        case .closed:
            return true
        case .halfOpen:
            return true
        case .open:
            guard let lastFailure = lastFailureTime else { return true }
            let elapsed = ContinuousClock.Instant.now - lastFailure
            let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            guard elapsedSeconds >= resetTimeout else { return false }
            state = .halfOpen
            return true
        }
    }

    /// Clears the failure count and closes the breaker, whatever state it was in.
    public func recordSuccess() {
        failureCount = 0
        state = .closed
    }

    /// Counts a failure and opens the breaker once the threshold is reached.
    ///
    /// The count keeps rising past the threshold, so a breaker that has failed many times
    /// still reopens on a single failure after one success — the count is reset, not the history.
    public func recordFailure() {
        failureCount += 1
        lastFailureTime = .now
        if failureCount >= failureThreshold {
            state = .open
        }
    }
}

// MARK: - SearchResultCache

/// Caches search results by query, bounded by entry count and by age.
///
/// The key is the exact query string paired with `maxResults`, so nothing is normalised:
/// `"swift"` and `"Swift"` are different entries, and asking for 5 results does not hit an
/// entry stored for 10.
///
/// Capacity is enforced on insert by evicting the least recently used entry, so the actor
/// never grows past `maxEntries`. Expiry is enforced on read only — a stale entry is
/// reported as a miss but stays in the cache, holding a slot until something evicts it.
public actor SearchResultCache {
    private struct CacheEntry {
        let results: [WebSearchResult]
        let timestamp: ContinuousClock.Instant
    }

    private struct CacheKey: Hashable {
        let query: String
        let maxResults: Int
    }

    private let ttl: TimeInterval
    private let maxEntries: Int
    private var cache: [CacheKey: CacheEntry] = [:]
    private var accessOrder: [CacheKey] = []

    /// Creates an empty cache.
    ///
    /// - Parameters:
    ///   - ttl: Seconds an entry stays valid, measured from when it was stored.
    ///   - maxEntries: Hard capacity. Nothing checks it for sanity, so `0` evicts on every insert.
    public init(ttl: TimeInterval, maxEntries: Int) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    /// Looks up a cached result, treating an expired entry as a miss.
    ///
    /// A hit refreshes the entry's position in the eviction order; a miss on an expired
    /// entry does not remove it.
    ///
    /// - Parameters:
    ///   - query: The exact query string used when the entry was stored.
    ///   - maxResults: The exact result count used when the entry was stored.
    public func get(query: String, maxResults: Int) -> [WebSearchResult]? {
        let key = CacheKey(query: query, maxResults: maxResults)
        guard let entry = cache[key] else { return nil }

        let elapsed = ContinuousClock.Instant.now - entry.timestamp
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if elapsedSeconds > ttl {
            return nil  // Expired. Left in place; capacity reclaims it later.
        }

        // Most recently used goes last, so evictOldest takes from the front.
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
            accessOrder.append(key)
        }

        return entry.results
    }

    /// Stores a result, evicting the least recently used entry first if the cache is full.
    ///
    /// Overwriting an existing key restarts its TTL and evicts nothing.
    ///
    /// - Parameters:
    ///   - results: Results to cache. An empty array is cached like any other value, so a
    ///     query that legitimately found nothing is not retried until the TTL expires.
    ///   - query: Query string, used verbatim as part of the key.
    ///   - maxResults: Result count, used as part of the key.
    public func set(_ results: [WebSearchResult], query: String, maxResults: Int) {
        let key = CacheKey(query: query, maxResults: maxResults)

        // Only a new key can push the count over capacity.
        if cache[key] == nil && cache.count >= maxEntries {
            evictOldest()
        }

        cache[key] = CacheEntry(results: results, timestamp: .now)

        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(key)
    }

    /// Empties the cache.
    public func clear() {
        cache.removeAll()
        accessOrder.removeAll()
    }

    /// Stored entries, including expired ones that have not yet been evicted.
    public var count: Int {
        cache.count
    }

    /// Drops the least recently used entry, expired or not.
    private func evictOldest() {
        guard let oldest = accessOrder.first else { return }
        accessOrder.removeFirst()
        cache.removeValue(forKey: oldest)
    }
}

// MARK: - ResilientSearchProvider

/// Wraps a search provider with a cache, a circuit breaker, a rate limiter and retries.
///
/// A search runs through them in this order: cache lookup, circuit-breaker admission, then
/// an attempt loop where each attempt waits on the rate limiter and, from the second
/// attempt on, first backs off exponentially from 500 ms.
///
/// Two consequences worth knowing before relying on it:
///
/// - **Every error is retried.** Nothing distinguishes a timeout from a rejected API key,
///   so a permanently broken credential is re-sent on every attempt.
/// - **Each failed attempt counts separately against the circuit breaker.** With the
///   defaults — two attempts, threshold five — three consecutive failing searches open the
///   circuit, not five.
///
/// The breaker is consulted once, before the loop, so retries continue even if it opens
/// partway through. Only successes are cached; failures are not.
public final class ResilientSearchProvider: WebSearchProvider, Sendable {
    private let provider: any WebSearchProvider
    private let rateLimiter: RateLimiter
    private let circuitBreaker: CircuitBreaker
    private let cache: SearchResultCache
    private let maxRetries: Int

    /// Wraps a provider. The cache, limiter and breaker belong to this instance alone, so
    /// two wrappers around the same provider do not share state.
    ///
    /// - Parameters:
    ///   - provider: The provider that performs the actual search.
    ///   - configuration: Tuning for all four mechanisms.
    public init(provider: any WebSearchProvider, configuration: SearchResilienceConfiguration = .default) {
        self.provider = provider
        self.rateLimiter = RateLimiter(maxRequestsPerSecond: configuration.maxRequestsPerSecond)
        self.circuitBreaker = CircuitBreaker(
            failureThreshold: configuration.failureThreshold,
            resetTimeout: configuration.resetTimeout
        )
        self.cache = SearchResultCache(ttl: configuration.cacheTTL, maxEntries: configuration.maxCacheEntries)
        self.maxRetries = configuration.maxRetries
    }

    /// Searches, serving a cached result if one is valid.
    ///
    /// - Throws: ``WebSearchError/circuitBreakerOpen`` when the breaker is open, otherwise
    ///   the error from the final attempt.
    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        if let cached = await cache.get(query: query, maxResults: maxResults) {
            return cached
        }

        // Checked once. An open breaker fails fast; a half-open one lets this through as a trial.
        let canExecute = await circuitBreaker.requestExecution()
        guard canExecute else {
            throw WebSearchError.circuitBreakerOpen
        }

        var lastError: Error?
        for attempt in 0...maxRetries {
            if attempt > 0 {
                // 500 ms, 1 s, 2 s, ... Cancellation during the backoff is swallowed and the
                // attempt proceeds.
                try? await Task.sleep(for: .milliseconds(500 * (1 << (attempt - 1))))
            }

            await rateLimiter.acquire()

            do {
                let results = try await provider.search(query: query, maxResults: maxResults)
                await circuitBreaker.recordSuccess()
                await cache.set(results, query: query, maxResults: maxResults)
                return results
            } catch {
                lastError = error
                await circuitBreaker.recordFailure()
            }
        }

        throw lastError ?? WebSearchError.invalidResponse
    }
}
