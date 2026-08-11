[English](./README.md) | 日本語

# swift-llm-mcp

Swift の LLM エージェントに「実際にできること」を与える — ファイルを読む、ページを取ってくる、Web を検索する。同梱のツールからでも、任意の MCP サーバーからでも。

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017+%20%7C%20macOS%2014+-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## 概要

モデルは渡されたツールを通してしか行動できない。このパッケージはその両側を用意する — そのまま動くツール群と、
他人が書いた MCP サーバーを同じ形のツールに変換するコネクタ。最終的にどちらもループへ渡す 1 本のリストに
収まるので、エージェントからはどの能力がどこ由来かは見えない。

- **箱に入っているツール** — ページ取得・JSON 取得・ヘッダ取得、Web 検索、ファイルの読み/書き/編集/移動/
  一覧/ツリー/glob/grep、画像生成、JavaScript 実行、そしてモデルが放っておくと間違える小物
  （時刻・四則演算・UUID・待機）
- **任意の MCP サーバーに繋ぐ** — macOS では stdio、あるいは Streamable HTTP（bearer / 独自ヘッダ認証）
- **サーバーにやらせることを絞る** — 読み取り専用の部分集合だけ取る、破壊的操作を落とす、許可するツール名を
  列挙する。モデルが一覧を見る前に決まる
- **ページは HTML ではなく Markdown で届く** — ナビゲーション・スクリプト・装飾は削がれ、長いページは
  1 回でコンテキストを埋め尽くさずに切り分けて読める
- **編集系ツールは先に読ませる** — 読んでいないファイルへの write / edit は拒否されるので、見ていない内容を
  上書きできない
- **取得エンジンは単体で立つ** — `WebFetchKit` は MCP にもツール層にも依存しないので、素のライブラリとして
  使える

## クイックスタート

同梱ツールからツールセットを組む:

```swift
import LLMMCP
import LLMTool

let tools = ToolSet {
    WebToolKit()
    FileSystemToolKit(allowedPaths: ["/path/to/workspace"])
    UtilityToolKit()
}
```

外部 MCP サーバーを足す。プレースホルダはループ開始前に一度だけ解決する:

```swift
let tools = ToolSet {
    MCPServer(
        command: "npx",
        arguments: ["-y", "@anthropic/mcp-server-filesystem", "/path/to/dir"]
    ).readOnly                                   // または .safe / .including(...) / .excluding(...)

    MCPServer(
        url: URL(string: "https://mcp.example.com/mcp")!,
        authorization: .bearer("your-access-token")
    )
}

let resolved = try await tools.resolvingMCPServers()
```

エージェントを介さず、取得エンジンだけを使う:

```swift
import WebFetchKit

let document = try await WebFetchEngine().fetch(url: "https://example.com")
print(document.text)          // HTML なら Markdown、それ以外はデコードしたテキスト
print(document.wasTruncated)  // maxContentSize を超えたら true
```

## ドキュメント

[**LLMMCP**](https://no-problem-dev.github.io/swift-llm-mcp/documentation/llmmcp/) —
MCP サーバーへの接続、同梱ツールキット、自作の書き方。
[Getting Started](https://no-problem-dev.github.io/swift-llm-mcp/documentation/llmmcp/gettingstarted/) を含む。

[**WebFetchKit**](https://no-problem-dev.github.io/swift-llm-mcp/documentation/webfetchkit/) —
取得エンジン、HTML → Markdown 変換、長いページの切り出し。

## インストール

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-llm-mcp.git", .upToNextMinor(from: "0.2.0")),
],
```

```swift
.product(name: "LLMMCP", package: "swift-llm-mcp"),
// ツール層なしで取得エンジンだけ欲しい場合:
.product(name: "WebFetchKit", package: "swift-llm-mcp"),
```

## 要件

- iOS 17.0+ / macOS 14.0+ — stdio の MCP サーバーはサブプロセスを起動するため macOS のみ
- Swift 6.2+

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
