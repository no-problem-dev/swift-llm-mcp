[English](./README.md) | 日本語

# swift-llm-mcp

> MCP サーバー接続・内蔵 ToolKit・`ToolKit`/`BuiltInTool` アダプタを提供する Swift パッケージ。[swift-llm-client](https://github.com/no-problem-dev/swift-llm-client) の `ToolSet` に外部ケイパビリティを解決して組み込む。

swift-llm-agent から分離されたツール解決レイヤー。エージェントランタイム全体に依存するのではなく、このパッケージだけへの絞った依存を持てるように設計されている。

---

## 提供モジュール

| モジュール | 用途 |
|---|---|
| `LLMMCP` | MCP サーバー接続・内蔵 ToolKit・ToolSet 拡張 |
| `WebFetchKit` | MCP/LLMTool 非依存の純粋な Web フェッチエンジン |
| `web-fetch-probe` | WebFetchKit の品質検証用 CLI ツール（実行ファイル） |

---

## インストール（Swift Package Manager）

`Package.swift` の `dependencies` に追加:

```swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-llm-mcp.git", from: "0.1.1"),
],
```

ターゲットに追加:

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "LLMMCP", package: "swift-llm-mcp"),
        // Web フェッチエンジン単体が必要な場合
        .product(name: "WebFetchKit", package: "swift-llm-mcp"),
    ]
),
```

**対応プラットフォーム**: macOS 14+、iOS 17+

---

## LLMMCP モジュール

### MCPServer — 外部 MCP サーバーへの接続

#### stdio（macOS のみ）

```swift
import LLMMCP
import LLMTool

// npx で MCP サーバーを起動し接続
let tools = ToolSet {
    MCPServer(
        command: "npx",
        arguments: ["-y", "@anthropic/mcp-server-filesystem", "/path/to/dir"]
    )
    .readOnly  // 読み取り専用ツールのみ

    MCPServer(
        command: "npx",
        arguments: ["-y", "@anthropic/mcp-server-brave-search"],
        environment: ["BRAVE_API_KEY": "your-key"]
    )
    .excluding("dangerous_tool")  // 特定ツールを除外
}

// MCPServer のプレースホルダーを実際のツールに解決してから使う
let resolved = try await tools.resolvingMCPServers()
```

#### HTTP（Streamable HTTP）

```swift
// 認証なし
MCPServer(url: URL(string: "http://localhost:8080/mcp")!)

// Bearer トークン認証（OAuth 2.1）
MCPServer(
    url: URL(string: "https://mcp.example.com/mcp")!,
    authorization: .bearer("your-access-token")
)

// カスタムヘッダー認証
MCPServer(
    url: URL(string: "https://mcp.example.com/mcp")!,
    authorization: .header("X-API-Key", "your-key")
)
```

#### プリセット — Notion MCP

```swift
let tools = ToolSet {
    MCPServer.notion(token: "ntn_xxxxx")
}
let resolved = try await tools.resolvingMCPServers()
```

#### ツール選択 API

```swift
server.readOnly               // 読み取り専用ツールのみ
server.safe                   // 破壊的操作を除外
server.including("tool1", "tool2")   // 指定ツールのみ
server.excluding("delete_file")      // 指定ツールを除外
server.all                    // すべてのツール（デフォルト）
```

---

### 内蔵 ToolKit — 外部 MCP サーバー不要のツール群

`ToolKit` プロトコルに準拠した型を `ToolSet {}` ブロック内に直接記述できる。

```swift
let tools = ToolSet {
    WebToolKit()
    WebSearchToolKit.brave(apiKey: "BRAVE_KEY")
    FileSystemToolKit(allowedPaths: ["/tmp/workspace"])
    UtilityToolKit()
}
```

#### WebToolKit — Web フェッチ

HTML を自動で Markdown に変換して返す。

```swift
// ドメイン制限あり
let tools = ToolSet {
    WebToolKit(allowedDomains: ["api.example.com", "docs.example.com"])
}
```

提供ツール:

| ツール名 | 説明 |
|---|---|
| `fetch` | URL を取得。HTML は自動 Markdown 変換。ページネーション対応（`start_index`/`max_length`） |
| `fetch_json` | URL から JSON を取得してパース |
| `fetch_headers` | HEAD リクエストで HTTP ヘッダーのみ取得 |

#### WebSearchToolKit — Web 検索

```swift
// Brave Search API
let tools = ToolSet {
    WebSearchToolKit.brave(apiKey: "BRAVE_KEY", searchLang: "ja", country: "JP")
}

// Serper API（日本語最適化）
let tools = ToolSet {
    WebSearchToolKit.serper(apiKey: "SERPER_KEY", gl: "jp", hl: "ja")
}

// フォールバックチェーン
let tools = ToolSet {
    WebSearchToolKit.withFallback(
        primary: BraveSearchProvider(apiKey: "BRAVE_KEY"),
        fallback: SerperSearchProvider(apiKey: "SERPER_KEY")
    )
}
```

提供ツール:

| ツール名 | 説明 |
|---|---|
| `web_search` | クエリで Web 検索。タイトル・URL・スニペット一覧を返す（最大 10 件） |

レジリエンス機能（デフォルト有効）: レート制限（1 req/s）、サーキットブレーカー、LRU+TTL キャッシュ（5 分）、リトライ。

#### FileSystemToolKit — ファイル操作

```swift
// iOS: サンドボックス内は全て許可（デフォルト）
let tools = ToolSet {
    FileSystemToolKit()
}

// macOS: 特定ディレクトリのみ許可
let tools = ToolSet {
    FileSystemToolKit(
        allowedPaths: ["/Users/user/projects"],
        workingDirectory: "/Users/user/projects"
    )
}

// Workspace から初期化
let tools = ToolSet {
    FileSystemToolKit(workspace: workspace)
}
```

提供ツール:

| ツール名 | 説明 |
|---|---|
| `read_file` | ファイル内容を読み取り |
| `read_multiple_files` | 複数ファイルを一括読み取り |
| `write_file` | ファイルを作成/上書き（事前 read 必須） |
| `edit_file` | 文字列置換によるファイル編集（事前 read 必須） |
| `create_directory` | ディレクトリ作成（親ディレクトリも自動作成） |
| `list_directory` | ディレクトリ内容一覧 |
| `directory_tree` | ディレクトリツリー表示（最大深さ指定可） |
| `move_file` | ファイル/ディレクトリの移動・名前変更 |
| `search_files` | グロブパターンでファイル検索 |
| `grep_files` | 正規表現でファイル内容を全文検索 |
| `get_file_info` | ファイルのサイズ・パーミッション・タイムスタンプ取得 |

#### ImageGenerationToolKit — 画像生成

```swift
let tools = ToolSet {
    // OpenAI (gpt-image-1)
    ImageGenerationToolKit.openai(apiKey: "sk-...")

    // fal.ai (FLUX.2 Schnell)
    ImageGenerationToolKit.falai(apiKey: "fal-...")

    // Gemini (Imagen 4)
    ImageGenerationToolKit.gemini(apiKey: "AIza...")
}
```

提供ツール:

| ツール名 | 説明 |
|---|---|
| `generate_image` | テキストプロンプトから画像を生成。サイズ（square/landscape/portrait）・品質（standard/hd）指定可 |

#### ScriptToolKit — JavaScript 実行（JavaScriptCore）

LLM が生成した JavaScript をサンドボックス内で実行する。`ios` オブジェクト経由でファイル操作と HTTP リクエストが可能。

```swift
let tools = ToolSet {
    ScriptToolKit(
        bridge: ScriptBridge(allowedPaths: ["/tmp/workspace"]),
        timeout: 30
    )
}
```

提供ツール:

| ツール名 | 説明 |
|---|---|
| `run_script` | JavaScript を実行。`ios.readFile(path)`/`ios.writeFile(path, content)`/`ios.fetch(url)` などの iOS ブリッジを提供 |

#### UtilityToolKit — 汎用ユーティリティ

```swift
let tools = ToolSet {
    UtilityToolKit(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
}
```

提供ツール:

| ツール名 | 説明 |
|---|---|
| `get_current_time` | 現在時刻を指定フォーマット・タイムゾーンで取得 |
| `calculate` | 基本的な数学計算（add/subtract/multiply/divide/power/sqrt/abs/round/floor/ceil） |
| `generate_uuid` | UUID 生成（standard/compact/uppercase、最大 100 件） |
| `sleep` | 指定秒数待機（0.001 〜 60 秒） |

---

### ToolKit プロトコル — カスタム ToolKit の実装

```swift
import LLMMCP
import LLMTool

public struct MyToolKit: ToolKit {
    public var name: String { "my-toolkit" }

    public var tools: [any Tool] {
        [
            BuiltInTool(
                name: "my_tool",
                description: "Does something useful",
                inputSchema: .object(
                    properties: ["input": .string(description: "Input text")],
                    required: ["input"]
                ),
                annotations: ToolAnnotations(readOnlyHint: true)
            ) { data in
                let input = try JSONDecoder().decode(MyInput.self, from: data)
                return .text("Result: \(input.input)")
            }
        ]
    }
}

// ToolSet に追加
let tools = ToolSet {
    MyToolKit()
}
```

---

## WebFetchKit モジュール

MCP や LLMTool に依存しない純粋な Web フェッチエンジン。`WebToolKit` の下層として使われるほか、エージェント外のコードからも直接利用できる。

```swift
import WebFetchKit

let engine = WebFetchEngine(
    allowedDomains: ["example.com"],  // nil で全許可
    timeout: 30,
    maxContentSize: 5 * 1024 * 1024  // 5MB
)

// HTML → Markdown 変換付きフェッチ
let doc = try await engine.fetch(url: "https://example.com/article")
print(doc.title ?? "no title")
print(doc.text)         // Markdown 化された本文
print(doc.wasTruncated) // maxContentSize 超過で切り詰めたか

// JSON フェッチ（生レスポンス）
let (status, body, url) = try await engine.fetchRawJSON(url: "https://api.example.com/data")

// ヘッダーのみ取得
let headers = try await engine.fetchHeaders(url: "https://example.com")
```

**自動処理**:
- HTML: SwiftSoup で本文抽出 → Markdown 変換
- RSS/Atom フィード: item 一覧を Markdown に整形
- DocC ドキュメント（Apple/Swift）: render JSON API から全文取得
- Bot チャレンジ / Cloudflare 等: `WebFetchError.challengeBlocked` に昇格
- バイナリコンテンツ（PDF・画像等）: `WebFetchError.binaryContent` に昇格

---

## 依存パッケージ

| パッケージ | 用途 |
|---|---|
| `swift-llm-client` (no-problem-dev) | `ToolSet` / `ToolSetBuilder` / `LLMTool` プロトコル |
| `swift-sdk` (modelcontextprotocol) | MCP プロトコル実装 |
| `SwiftSoup` | HTML パース・Markdown 変換 |
| `swift-http-transport` (no-problem-dev) | HTTP トランスポート抽象化 |
| `swift-structured-data` (no-problem-dev) | JSON パース・シリアライズ |

---

## 関連ドキュメント

- [swift-llm-client](https://github.com/no-problem-dev/swift-llm-client) — `ToolSet`・`Tool` プロトコルの定義元
- [swift-http-transport](https://github.com/no-problem-dev/swift-http-transport) — HTTP トランスポート抽象化
- [Model Context Protocol](https://modelcontextprotocol.io/) — MCP 仕様
