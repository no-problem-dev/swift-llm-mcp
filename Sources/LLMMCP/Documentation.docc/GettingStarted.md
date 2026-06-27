# Getting Started with LLMMCP

MCP サーバー接続と内蔵 ToolKit を `ToolSet` に組み込む方法を説明します。

## Installation

Swift Package Manager で追加します。

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-llm-mcp.git", from: "0.1.0"),
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: [
            .product(name: "LLMMCP", package: "swift-llm-mcp"),
        ]
    ),
]
```

**対応プラットフォーム**: macOS 14+、iOS 17+

## Basic Usage

### 内蔵 ToolKit を使う（推奨スタート）

外部プロセスや MCP サーバー不要で、すぐに使い始められます。

```swift
import LLMMCP
import LLMTool

let tools = ToolSet {
    // Web フェッチ（HTML → Markdown 自動変換）
    WebToolKit()

    // ファイルシステム操作（macOS: パス制限あり）
    FileSystemToolKit(allowedPaths: ["/Users/you/projects"])

    // 現在時刻・計算・UUID などの汎用ユーティリティ
    UtilityToolKit()

    // JavaScript 実行（JavaScriptCore）
    ScriptToolKit(bridge: ScriptBridge(allowedPaths: ["/tmp"]))
}
// ToolSet はそのままエージェントに渡せる（MCP 解決不要）
```

### 外部 MCP サーバーに接続する

```swift
// stdio トランスポート（macOS のみ）
let tools = ToolSet {
    MCPServer(
        command: "npx",
        arguments: ["-y", "@anthropic/mcp-server-filesystem", "/path/to/dir"]
    ).readOnly  // 読み取り専用ツールのみ使用
}

// MCP プレースホルダーを実際のツールに解決してから使う
let resolved = try await tools.resolvingMCPServers()
```

### HTTP MCP サーバーに接続する

```swift
// Bearer トークン認証（OAuth 2.1）
let tools = ToolSet {
    MCPServer(
        url: URL(string: "https://mcp.notion.com/mcp")!,
        authorization: .bearer("ntn_xxxxx")
    )
}

// Notion 専用プリセット
let notion = MCPServer.notion(token: "ntn_xxxxx")
```

### ツール選択を絞り込む

```swift
let server = MCPServer(command: "npx", arguments: [...])

server.readOnly               // 読み取り専用ツールのみ
server.safe                   // 破壊的操作を除外
server.including("read_file", "list_directory")  // 指定ツールのみ
server.excluding("delete_file")                  // 指定ツールを除外
```

## カスタム ToolKit を実装する

``ToolKit`` プロトコルと ``BuiltInTool`` を使うと、独自ツールを `ToolSet` に追加できます。

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
    WebToolKit()
}
```
