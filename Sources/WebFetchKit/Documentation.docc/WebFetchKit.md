# ``WebFetchKit``

MCP・LLMTool に依存しない純粋な Web フェッチ／HTML 抽出エンジン。

## Overview

`WebFetchKit` は URL を取得し、LLM が消費しやすいテキスト（HTML は Markdown）に変換する
コアエンジンライブラリ。MCP サーバーや LLMTool アダプタには一切依存せず、
`LLMMCP` の `WebToolKit`、`web-fetch-probe`、その他エージェントから再利用できる。

```swift
import WebFetchKit

// エンジンを初期化（全パラメータにデフォルト値あり）
let engine = WebFetchEngine(
    allowedDomains: ["docs.swift.org", "github.com"],
    timeout: 30,
    maxContentSize: 5 * 1024 * 1024
)

// HTML ページを取得して Markdown に変換
let doc = try await engine.fetch(url: "https://docs.swift.org/swift-book/")
print(doc.title ?? "")   // ページタイトル
print(doc.text)          // 抽出済み Markdown
print(doc.wasTruncated)  // maxContentSize 超過で切り詰めたか

// JSON エンドポイントを取得（パースは呼び出し側）
let (status, body, url) = try await engine.fetchRawJSON(
    url: "https://api.example.com/data",
    method: "POST",
    body: #"{"query":"hello"}"#
)

// HTTP ヘッダーのみ取得（HEAD リクエスト）
let headers = try await engine.fetchHeaders(url: "https://example.com/file.pdf")
print(headers.statusCode)
```

`WebFetchEngine` は HTML ページを自動判定し、SwiftSoup ベースの `SwiftSoupContentExtractor`
で本文を抽出して Markdown に変換する。RSS/Atom フィードはアイテム一覧の Markdown に整形し、
DocC ドキュメント（Apple/Swift）は render JSON から全文を取得する。
bot チャレンジや JS 必須インタースティシャルは `WebFetchError.challengeBlocked` として
明示的に昇格されるため、LLM が空コンテンツを成功と誤認しない。

コンテンツ抽出戦略を差し替えるには `WebContentExtractor` プロトコルを実装し、
`WebFetchEngine.init(extractor:)` に渡す。

```swift
import WebFetchKit

struct CustomExtractor: WebContentExtractor {
    func extract(html: String, url: URL) throws -> ExtractedContent {
        // 独自の抽出ロジック
        ExtractedContent(title: "Custom", content: "...")
    }
}

let engine = WebFetchEngine(extractor: CustomExtractor())
```

`WebFetchKit` が属する `swift-llm-mcp` パッケージでは、`LLMMCP` が MCP サーバー接続と
内蔵 ToolKit を提供し、その `WebToolKit` がこのエンジンを LLM ツールとして公開する。

## Topics

### フェッチエンジン

- ``WebFetchEngine``
- ``FetchedDocument``
- ``WebFetchHeadersResult``

### コンテンツ抽出

- ``WebContentExtractor``
- ``ExtractedContent``
- ``SwiftSoupContentExtractor``

### エラー型

- ``WebFetchError``
