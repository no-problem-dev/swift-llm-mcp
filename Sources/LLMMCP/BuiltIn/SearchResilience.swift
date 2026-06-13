import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - SearchResilienceConfiguration

/// レジリエンス機能の設定
public struct SearchResilienceConfiguration: Sendable {
    /// 1秒あたりの最大リクエスト数
    public let maxRequestsPerSecond: Double

    /// サーキットブレーカーの失敗閾値
    public let failureThreshold: Int

    /// サーキットブレーカーのリセット待機時間（秒）
    public let resetTimeout: TimeInterval

    /// キャッシュのTTL（秒）
    public let cacheTTL: TimeInterval

    /// キャッシュの最大エントリ数
    public let maxCacheEntries: Int

    /// リトライ回数
    public let maxRetries: Int

    /// デフォルト設定
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

/// トークンバケット方式のレートリミッター
public actor RateLimiter {
    private let maxTokens: Double
    private let refillRate: Double // tokens per second
    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant

    /// RateLimiterを作成
    ///
    /// - Parameter maxRequestsPerSecond: 1秒あたりの最大リクエスト数
    public init(maxRequestsPerSecond: Double) {
        self.maxTokens = max(maxRequestsPerSecond, 1.0)
        self.refillRate = maxRequestsPerSecond
        self.tokens = maxTokens
        self.lastRefill = .now
    }

    /// リクエスト許可を待機
    ///
    /// トークンが利用可能になるまで待機し、1トークンを消費します。
    public func acquire() async {
        refillTokens()

        if tokens >= 1.0 {
            tokens -= 1.0
            return
        }

        // Wait for token to become available
        let waitTime = (1.0 - tokens) / refillRate
        do {
            try await Task.sleep(for: .milliseconds(Int(waitTime * 1000)))
        } catch {
            // Cancelled - allow caller to handle
            return
        }
        refillTokens()
        tokens = max(tokens - 1.0, 0)
    }

    private func refillTokens() {
        let now = ContinuousClock.Instant.now
        let elapsed = now - lastRefill
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(maxTokens, tokens + elapsedSeconds * refillRate)
        lastRefill = now
    }
}

// MARK: - CircuitBreaker

/// サーキットブレーカー（3状態遷移）
public actor CircuitBreaker {
    /// サーキットブレーカーの状態
    public enum State: Sendable {
        case closed
        case open
        case halfOpen
    }

    private let failureThreshold: Int
    private let resetTimeout: TimeInterval
    private var failureCount: Int = 0
    private var lastFailureTime: ContinuousClock.Instant?
    private(set) public var state: State = .closed

    /// CircuitBreakerを作成
    ///
    /// - Parameters:
    ///   - failureThreshold: open状態に遷移する失敗回数
    ///   - resetTimeout: open→halfOpenに遷移する待機時間（秒）
    public init(failureThreshold: Int, resetTimeout: TimeInterval) {
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
    }

    /// リクエストの実行可否を確認し、必要に応じて状態遷移
    ///
    /// - closed: 常にtrueを返す
    /// - halfOpen: 常にtrueを返す
    /// - open: resetTimeout経過後にhalfOpenに遷移してtrueを返す、未経過ならfalseを返す
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

    /// 成功を記録
    public func recordSuccess() {
        failureCount = 0
        state = .closed
    }

    /// 失敗を記録
    public func recordFailure() {
        failureCount += 1
        lastFailureTime = .now
        if failureCount >= failureThreshold {
            state = .open
        }
    }
}

// MARK: - SearchResultCache

/// LRU + TTL キャッシュ
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

    /// SearchResultCacheを作成
    ///
    /// - Parameters:
    ///   - ttl: エントリの有効期限（秒）
    ///   - maxEntries: 最大エントリ数
    public init(ttl: TimeInterval, maxEntries: Int) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    /// キャッシュを参照
    ///
    /// - Parameters:
    ///   - query: 検索クエリ
    ///   - maxResults: 最大結果数
    /// - Returns: キャッシュヒットした結果、またはnil
    public func get(query: String, maxResults: Int) -> [WebSearchResult]? {
        let key = CacheKey(query: query, maxResults: maxResults)
        guard let entry = cache[key] else { return nil }

        let elapsed = ContinuousClock.Instant.now - entry.timestamp
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if elapsedSeconds > ttl {
            return nil // Expired
        }

        // Move to end of access order (LRU)
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
            accessOrder.append(key)
        }

        return entry.results
    }

    /// キャッシュに保存
    ///
    /// - Parameters:
    ///   - results: 検索結果
    ///   - query: 検索クエリ
    ///   - maxResults: 最大結果数
    public func set(_ results: [WebSearchResult], query: String, maxResults: Int) {
        let key = CacheKey(query: query, maxResults: maxResults)

        // Evict LRU if at capacity
        if cache[key] == nil && cache.count >= maxEntries {
            evictOldest()
        }

        cache[key] = CacheEntry(results: results, timestamp: .now)

        // Update access order
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(key)
    }

    /// キャッシュをクリア
    public func clear() {
        cache.removeAll()
        accessOrder.removeAll()
    }

    /// 現在のエントリ数
    public var count: Int {
        cache.count
    }

    private func evictOldest() {
        guard let oldest = accessOrder.first else { return }
        accessOrder.removeFirst()
        cache.removeValue(forKey: oldest)
    }
}

// MARK: - ResilientSearchProvider

/// レジリエンス機能を統合した検索プロバイダーラッパー
///
/// キャッシュ → レート制限 → サーキットブレーカー → リトライの順で実行します。
public final class ResilientSearchProvider: WebSearchProvider, Sendable {
    private let provider: any WebSearchProvider
    private let rateLimiter: RateLimiter
    private let circuitBreaker: CircuitBreaker
    private let cache: SearchResultCache
    private let maxRetries: Int

    /// ResilientSearchProviderを作成
    ///
    /// - Parameters:
    ///   - provider: ラップする検索プロバイダー
    ///   - configuration: レジリエンス設定
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

    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        // 1. Check cache
        if let cached = await cache.get(query: query, maxResults: maxResults) {
            return cached
        }

        // 2. Request execution from circuit breaker (includes state transition)
        let canExecute = await circuitBreaker.requestExecution()
        guard canExecute else {
            throw WebSearchError.circuitBreakerOpen
        }

        // 3. Rate limiting + retry
        var lastError: Error?
        for attempt in 0...maxRetries {
            if attempt > 0 {
                // Exponential backoff for retries
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
