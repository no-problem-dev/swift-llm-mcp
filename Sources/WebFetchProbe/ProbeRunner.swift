import Foundation
import LLMMCP
import LLMTool
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - ProbeResult

/// Everything one probed URL produced. Failures are recorded, never swallowed.
struct ProbeResult: Codable {
    let url: String
    let category: ProbeCategory
    let expected: ExpectedOutcome
    let layer: FailureLayer
    /// One line explaining the classification, for a human reading the report.
    let detail: String
    /// Characters extracted, or 0 on failure.
    let contentLength: Int
    let title: String?
    let wasTruncated: Bool
    let hasMore: Bool
    /// Wall-clock seconds for the whole fetch, including extraction.
    let elapsed: Double
    /// Whether the outcome matched what the corpus predicted. `false` is the interesting
    /// value: it marks a page that broke in an unexpected way.
    let matchedExpectation: Bool
    /// Rough token count for the extracted text. Zero on failure.
    var approxTokens: Int = 0
    /// Noise breakdown, present only when something was extracted.
    var noise: NoiseReport? = nil
}

// MARK: - fetch tool output

/// The `fetch` tool's JSON shape, redeclared here because `WebToolKit` keeps its own copy private.
///
/// A field rename in `WebToolKit` would not break the build; it would silently stop decoding
/// here and every probe would fall into the "non-FetchResult JSON" branch.
private struct FetchToolOutput: Decodable {
    let url: String
    let title: String?
    let content: String
    let contentLength: Int
    let wasTruncated: Bool
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case url, title, content
        case contentLength = "content_length"
        case wasTruncated = "was_truncated"
        case hasMore = "has_more"
    }
}

// MARK: - ProbeRunner

/// Fetches every corpus entry and records how each one turned out.
struct ProbeRunner {
    /// Per-request timeout handed to each `WebToolKit`.
    let timeout: TimeInterval
    /// How many fetches run at once. Raising it shortens the run but also raises the chance
    /// of tripping a site's rate limiting, which shows up as extra 429s in the report.
    let maxConcurrency: Int

    /// Runs the whole corpus, keeping `maxConcurrency` fetches in flight.
    ///
    /// Results come back in corpus order regardless of completion order, so two runs are
    /// directly comparable. Never throws: a failed fetch becomes a ``ProbeResult`` with a
    /// failure layer, which is the entire point of the tool. Progress is written to stderr
    /// so it stays out of the report on stdout.
    func run(_ entries: [CorpusEntry]) async -> [ProbeResult] {
        var results = [ProbeResult?](repeating: nil, count: entries.count)

        await withTaskGroup(of: (Int, ProbeResult).self) { group in
            var nextIndex = 0
            while nextIndex < min(maxConcurrency, entries.count) {
                let i = nextIndex
                group.addTask { (i, await self.probe(entries[i])) }
                nextIndex += 1
            }
            // Refill on each completion to hold the in-flight count steady.
            while let (idx, result) = await group.next() {
                results[idx] = result
                let done = entries.count - results.compactMap { $0 }.count
                FileHandle.standardError.write(
                    "  [\(entries.count - done)/\(entries.count)] \(result.layer.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(result.url)\n".data(using: .utf8)!
                )
                if nextIndex < entries.count {
                    let i = nextIndex
                    group.addTask { (i, await self.probe(entries[i])) }
                    nextIndex += 1
                }
            }
        }

        return results.compactMap { $0 }
    }

    /// Probes one URL through a real `WebToolKit`, built fresh so no state carries between entries.
    ///
    /// Goes through the actual `fetch` tool rather than `WebFetchEngine` directly, so the
    /// tool's own argument decoding and pagination are exercised too.
    private func probe(_ entry: CorpusEntry) async -> ProbeResult {
        let toolkit = WebToolKit(timeout: timeout)
        guard let fetch = toolkit.tool(named: "fetch") else {
            return result(entry, .unknown, "fetch tool not found", 0, nil, false, false, 0)
        }

        // 200,000 characters, far past the tool's 5000 default, so noise analysis sees the
        // whole page. raw is left off, so this measures the Markdown an LLM would receive.
        let inputDict: [String: Any] = ["url": entry.url, "max_length": 200_000]
        let input = try? JSONSerialization.data(withJSONObject: inputDict)
        let start = Date()

        do {
            let toolResult = try await fetch.execute(with: input ?? Data())
            let elapsed = Date().timeIntervalSince(start)

            switch toolResult {
            case .json(let data):
                if let out = try? JSONDecoder().decode(FetchToolOutput.self, from: data) {
                    let layer: FailureLayer = out.contentLength < FailureClassifier.thinContentThreshold
                        ? .okThinContent : .ok
                    let detail = layer == .okThinContent
                        ? "抽出本文 \(out.contentLength) 文字（閾値 \(FailureClassifier.thinContentThreshold) 未満）"
                        : "抽出本文 \(out.contentLength) 文字"
                    // Noise analysis only makes sense when there is content to analyse.
                    let noise = ContentQualityAnalyzer.analyze(out.content)
                    let tokens = NoiseReport.approxTokens(out.content)
                    return result(entry, layer, detail, out.contentLength, out.title,
                                  out.wasTruncated, out.hasMore, elapsed,
                                  approxTokens: tokens, noise: noise)
                }
                // JSON in an unexpected shape. Counted as a success and judged by byte length,
                // so a decoding break here looks like a very short page rather than an error.
                let len = data.count
                return result(entry, len < FailureClassifier.thinContentThreshold ? .okThinContent : .ok,
                              "non-FetchResult JSON, \(len) bytes", len, nil, false, false, elapsed)
            case .text(let s):
                let layer: FailureLayer = s.count < FailureClassifier.thinContentThreshold ? .okThinContent : .ok
                return result(entry, layer, "text result \(s.count) 文字", s.count, nil, false, false, elapsed)
            case .error(let msg):
                return result(entry, .unknown, "ToolResult.error: \(msg)", 0, nil, false, false, elapsed)
            case .textWithMedia(let s, _):
                return result(entry, .ok, "textWithMedia \(s.count) 文字", s.count, nil, false, false, elapsed)
            }
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            let (layer, detail) = FailureClassifier.classify(error: error)
            return result(entry, layer, detail, 0, nil, false, false, elapsed)
        }
    }

    private func result(_ entry: CorpusEntry, _ layer: FailureLayer, _ detail: String,
                        _ contentLength: Int, _ title: String?, _ wasTruncated: Bool,
                        _ hasMore: Bool, _ elapsed: Double,
                        approxTokens: Int = 0, noise: NoiseReport? = nil) -> ProbeResult {
        ProbeResult(
            url: entry.url, category: entry.category, expected: entry.expected,
            layer: layer, detail: detail, contentLength: contentLength, title: title,
            wasTruncated: wasTruncated, hasMore: hasMore, elapsed: elapsed,
            matchedExpectation: ExpectationMatcher.matches(expected: entry.expected, actual: layer),
            approxTokens: approxTokens, noise: noise
        )
    }
}

// MARK: - ExpectationMatcher

/// Decides whether a probe's outcome agrees with what the corpus predicted for it.
///
/// Deliberately permissive: several layers satisfy each expectation. The purpose is to
/// surface pages that broke in a way nobody anticipated, not to pin down an exact outcome.
enum ExpectationMatcher {
    /// Reports whether `actual` is one of the outcomes `expected` allows.
    static func matches(expected: ExpectedOutcome, actual: FailureLayer) -> Bool {
        switch expected {
        case .readableSuccess:
            return actual == .ok
        case .thinContentLikely:
            return actual == .ok || actual == .okThinContent
        case .httpBlockedLikely:
            return actual == .httpClientError || actual == .httpServerError || actual == .challengeBlocked
        case .notFound:
            return actual == .httpClientError
        case .networkError:
            return actual == .networkTimeout || actual == .networkDNS
                || actual == .networkTLS || actual == .networkOther
        case .invalidURL:
            return actual == .urlValidation
        case .binaryLikely:
            // Binary content is classified as contentTooLarge. Hotlink protection can also
            // turn it into a 4xx, and some hosts serve it as text, so all four are accepted.
            return actual == .contentTooLarge || actual == .httpClientError
                || actual == .ok || actual == .okThinContent
        case .jsonSuccess:
            return actual == .ok || actual == .okThinContent
        }
    }
}
