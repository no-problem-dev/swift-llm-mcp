# ``LLMMCP``

MCP サーバー接続・内蔵 ToolKit・`ToolKit`/`BuiltInTool` アダプタを提供する Swift パッケージ。

## Overview

`LLMMCP` は、`swift-llm-client` の `ToolSet` に外部ケイパビリティを解決して組み込むためのツール解決レイヤー。外部 MCP サーバーへの接続と、MCP サーバー不要の内蔵 ToolKit の両方を提供する。

`swift-llm-mcp` パッケージは `LLMMCP` と `WebFetchKit` の 2 ライブラリで構成される。
`WebFetchKit` は MCP・LLMTool に依存しない純粋な Web フェッチ／HTML 抽出エンジンで、
`LLMMCP` の `WebToolKit` はその上に構築された LLM ツールアダプタ。
Web フェッチ能力を別のコンテキスト（CLI ツール、テスト、非 MCP エージェントなど）で
直接使いたい場合は `import WebFetchKit` で `WebFetchEngine` を単独利用できる。

```swift
import LLMMCP
import LLMTool

// 外部 MCP サーバーと内蔵 ToolKit を組み合わせる
let tools = ToolSet {
    // 外部 MCP サーバー（macOS のみ）
    MCPServer(
        command: "npx",
        arguments: ["-y", "@anthropic/mcp-server-filesystem", "/path/to/dir"]
    ).readOnly

    // 内蔵 ToolKit（MCP サーバー不要）
    WebToolKit()
    FileSystemToolKit(allowedPaths: ["/tmp/workspace"])
    UtilityToolKit()
}

// MCP サーバープレースホルダーを実際のツールに解決
let resolved = try await tools.resolvingMCPServers()
```

## Topics

### 基本

- <doc:GettingStarted>

### MCP サーバー接続

- ``MCPServer``
- ``MCPServerProtocol``
- ``MCPConfiguration``
- ``MCPTransport``
- ``MCPAuthorization``
- ``MCPToolSelection``
- ``MCPToolCapabilities``

### 内蔵 ToolKit

- ``ToolKit``
- ``BuiltInTool``
- ``WebToolKit``
- ``FileSystemToolKit``
- ``ScriptToolKit``
- ``ScriptBridge``
- ``WebSearchToolKit``
- ``ImageGenerationToolKit``
- ``UtilityToolKit``

### エラー型

- ``ScriptToolKitError``
- ``FileSystemToolKitError``
