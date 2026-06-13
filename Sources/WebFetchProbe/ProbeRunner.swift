import Foundation
import LLMMCP
import LLMTool
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - ProbeResult

/// 1 URL を fetch した結果の全記録。成功も失敗も握りつぶさず capture する。
struct ProbeResult: Codable {
    let url: String
    let category: ProbeCategory
    let expected: ExpectedOutcome
    let layer: FailureLayer
    let detail: String
    /// 抽出本文の文字数（成功時のみ。失敗時は 0）
    let contentLength: Int
    let title: String?
    let wasTruncated: Bool
    let hasMore: Bool
    /// 所要時間（秒）
    let elapsed: Double
    /// 期待結末と実際の分類が整合したか
    let matchedExpectation: Bool
    /// 概算トークン数（取得できた本文ベース）
    var approxTokens: Int = 0
    /// ペイロード品質分析（成功時のみ）
    var noise: NoiseReport? = nil
}

// MARK: - fetch の JSON 出力（WebToolKit 内 private なのでここで再定義）

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

struct ProbeRunner {
    let timeout: TimeInterval
    let maxConcurrency: Int

    /// コーパス全体を並列実行する。順序はコーパス通りに揃える。
    func run(_ entries: [CorpusEntry]) async -> [ProbeResult] {
        var results = [ProbeResult?](repeating: nil, count: entries.count)

        await withTaskGroup(of: (Int, ProbeResult).self) { group in
            var nextIndex = 0
            // 初期投入
            while nextIndex < min(maxConcurrency, entries.count) {
                let i = nextIndex
                group.addTask { (i, await self.probe(entries[i])) }
                nextIndex += 1
            }
            // 1 件完了するたびに次を投入（同時実行数を maxConcurrency に保つ）
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

    /// 1 件を実行。本物の WebToolKit を毎回生成し、fetch ツールを呼ぶ。
    private func probe(_ entry: CorpusEntry) async -> ProbeResult {
        let toolkit = WebToolKit(timeout: timeout)
        guard let fetch = toolkit.tool(named: "fetch") else {
            return result(entry, .unknown, "fetch tool not found", 0, nil, false, false, 0)
        }

        // 分析のため本文を大きめに取得（fetch の既定 max_length=5000 では切れる）。
        // LLM が実際に受け取る Markdown 抽出結果（raw=false）を対象にする。
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
                    // 成功系のみペイロード品質を分析（無駄トークンの所在を定量化）
                    let noise = ContentQualityAnalyzer.analyze(out.content)
                    let tokens = NoiseReport.approxTokens(out.content)
                    return result(entry, layer, detail, out.contentLength, out.title,
                                  out.wasTruncated, out.hasMore, elapsed,
                                  approxTokens: tokens, noise: noise)
                }
                // JSON だが期待構造でない（fetch_json 等の別形）→ 成功扱いだが内容で判定
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

/// 事前期待 (``ExpectedOutcome``) と実際の分類 (``FailureLayer``) が整合するか判定。
/// 「想定外の壊れ方」を浮かび上がらせるための緩い対応表。
enum ExpectationMatcher {
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
            // バイナリは P0-b で contentTooLarge に分類される。hotlink保護で 4xx もありうる
            return actual == .contentTooLarge || actual == .httpClientError
                || actual == .ok || actual == .okThinContent
        case .jsonSuccess:
            return actual == .ok || actual == .okThinContent
        }
    }
}
