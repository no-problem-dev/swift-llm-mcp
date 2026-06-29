English | [日本語](./README.ja.md)

# swift-llm-mcp

> A Swift package providing MCP server connections, built-in ToolKits, and `ToolKit`/`BuiltInTool` adapters. Resolves external capabilities into `ToolSet` from [swift-llm-client](https://github.com/no-problem-dev/swift-llm-client).

Extracted from swift-llm-agent as a standalone tool-resolution layer, so dependents can take a narrower dependency on just this package rather than the full agent runtime.

---

## Modules

| Module | Purpose |
|---|---|
| `LLMMCP` | MCP server connections, built-in ToolKits, ToolSet extensions |
| `WebFetchKit` | Pure web fetch engine with no MCP/LLMTool dependencies |
| `web-fetch-probe` | CLI quality-verification tool for WebFetchKit (executable) |

---

## Installation (Swift Package Manager)

Add to `dependencies` in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-llm-mcp.git", from: "0.1.1"),
],
```

Add to your target:

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "LLMMCP", package: "swift-llm-mcp"),
        // If you need the web fetch engine standalone:
        .product(name: "WebFetchKit", package: "swift-llm-mcp"),
    ]
),
```

**Platforms**: macOS 14+, iOS 17+

---

## LLMMCP Module

### MCPServer — External MCP Server Connections

#### stdio (macOS only)

```swift
import LLMMCP
import LLMTool

// Launch an MCP server via npx and connect
let tools = ToolSet {
    MCPServer(
        command: "npx",
        arguments: ["-y", "@anthropic/mcp-server-filesystem", "/path/to/dir"]
    )
    .readOnly  // Use read-only tools only

    MCPServer(
        command: "npx",
        arguments: ["-y", "@anthropic/mcp-server-brave-search"],
        environment: ["BRAVE_API_KEY": "your-key"]
    )
    .excluding("dangerous_tool")  // Exclude specific tools
}

// Resolve MCP placeholders to actual tools before use
let resolved = try await tools.resolvingMCPServers()
```

#### HTTP (Streamable HTTP)

```swift
// No auth
MCPServer(url: URL(string: "http://localhost:8080/mcp")!)

// Bearer token auth (OAuth 2.1)
MCPServer(
    url: URL(string: "https://mcp.example.com/mcp")!,
    authorization: .bearer("your-access-token")
)

// Custom header auth
MCPServer(
    url: URL(string: "https://mcp.example.com/mcp")!,
    authorization: .header("X-API-Key", "your-key")
)
```

#### Preset — Notion MCP

```swift
let tools = ToolSet {
    MCPServer.notion(token: "ntn_xxxxx")
}
let resolved = try await tools.resolvingMCPServers()
```

#### Tool Selection API

```swift
server.readOnly               // Read-only tools only
server.safe                   // Exclude destructive operations
server.including("tool1", "tool2")   // Specific tools only
server.excluding("delete_file")      // Exclude specific tools
server.all                    // All tools (default)
```

---

### Built-in ToolKits — No External MCP Server Required

Types conforming to `ToolKit` can be placed directly inside a `ToolSet {}` block.

```swift
let tools = ToolSet {
    WebToolKit()
    WebSearchToolKit.brave(apiKey: "BRAVE_KEY")
    FileSystemToolKit(allowedPaths: ["/tmp/workspace"])
    UtilityToolKit()
}
```

#### WebToolKit — Web Fetch

Automatically converts HTML responses to Markdown.

```swift
// Restrict to specific domains
let tools = ToolSet {
    WebToolKit(allowedDomains: ["api.example.com", "docs.example.com"])
}
```

Provided tools:

| Tool | Description |
|---|---|
| `fetch` | Fetch a URL. HTML is automatically converted to Markdown. Supports pagination via `start_index`/`max_length` |
| `fetch_json` | Fetch and parse JSON from a URL |
| `fetch_headers` | Fetch HTTP headers only via HEAD request |

#### WebSearchToolKit — Web Search

```swift
// Brave Search API
let tools = ToolSet {
    WebSearchToolKit.brave(apiKey: "BRAVE_KEY", searchLang: "en", country: "US")
}

// Serper API (optimized for Japanese)
let tools = ToolSet {
    WebSearchToolKit.serper(apiKey: "SERPER_KEY", gl: "jp", hl: "ja")
}

// Fallback chain
let tools = ToolSet {
    WebSearchToolKit.withFallback(
        primary: BraveSearchProvider(apiKey: "BRAVE_KEY"),
        fallback: SerperSearchProvider(apiKey: "SERPER_KEY")
    )
}
```

Provided tools:

| Tool | Description |
|---|---|
| `web_search` | Search the web and return titles, URLs, and snippets (up to 10 results) |

Resilience features (enabled by default): rate limiting (1 req/s), circuit breaker, LRU+TTL cache (5 min), retry.

#### FileSystemToolKit — File Operations

```swift
// iOS: all sandbox paths allowed (default)
let tools = ToolSet {
    FileSystemToolKit()
}

// macOS: restrict to specific directories
let tools = ToolSet {
    FileSystemToolKit(
        allowedPaths: ["/Users/user/projects"],
        workingDirectory: "/Users/user/projects"
    )
}

// Initialize from a Workspace
let tools = ToolSet {
    FileSystemToolKit(workspace: workspace)
}
```

Provided tools:

| Tool | Description |
|---|---|
| `read_file` | Read file contents |
| `read_multiple_files` | Read multiple files at once |
| `write_file` | Create or overwrite a file (prior read required) |
| `edit_file` | Edit a file by string replacement (prior read required) |
| `create_directory` | Create a directory (parent directories created automatically) |
| `list_directory` | List directory contents |
| `directory_tree` | Recursive directory tree view (configurable max depth) |
| `move_file` | Move or rename a file/directory |
| `search_files` | Search for files by glob pattern |
| `grep_files` | Full-text search with a regular expression |
| `get_file_info` | Get file size, permissions, and timestamps |

#### ImageGenerationToolKit — Image Generation

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

Provided tools:

| Tool | Description |
|---|---|
| `generate_image` | Generate an image from a text prompt. Size (square/landscape/portrait) and quality (standard/hd) are configurable |

#### ScriptToolKit — JavaScript Execution (JavaScriptCore)

Executes LLM-generated JavaScript in a sandboxed environment. File operations and HTTP requests are available via the `ios` object.

```swift
let tools = ToolSet {
    ScriptToolKit(
        bridge: ScriptBridge(allowedPaths: ["/tmp/workspace"]),
        timeout: 30
    )
}
```

Provided tools:

| Tool | Description |
|---|---|
| `run_script` | Execute JavaScript. Provides an iOS bridge via `ios.readFile(path)`, `ios.writeFile(path, content)`, `ios.fetch(url)`, etc. |

#### UtilityToolKit — General Utilities

```swift
let tools = ToolSet {
    UtilityToolKit(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
}
```

Provided tools:

| Tool | Description |
|---|---|
| `get_current_time` | Get the current time in a specified format and timezone |
| `calculate` | Basic math operations (add/subtract/multiply/divide/power/sqrt/abs/round/floor/ceil) |
| `generate_uuid` | Generate UUIDs (standard/compact/uppercase, up to 100 at once) |
| `sleep` | Wait for a specified duration (0.001–60 seconds) |

---

### ToolKit Protocol — Implementing Custom ToolKits

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

// Add to ToolSet
let tools = ToolSet {
    MyToolKit()
}
```

---

## WebFetchKit Module

A pure web fetch engine with no MCP or LLMTool dependencies. Used as the underlying layer by `WebToolKit`, and also directly importable from outside an agent context.

```swift
import WebFetchKit

let engine = WebFetchEngine(
    allowedDomains: ["example.com"],  // nil to allow all
    timeout: 30,
    maxContentSize: 5 * 1024 * 1024  // 5 MB
)

// Fetch with HTML-to-Markdown conversion
let doc = try await engine.fetch(url: "https://example.com/article")
print(doc.title ?? "no title")
print(doc.text)         // Markdown-extracted body
print(doc.wasTruncated) // true if truncated at maxContentSize

// Fetch JSON (raw response)
let (status, body, url) = try await engine.fetchRawJSON(url: "https://api.example.com/data")

// Fetch headers only
let headers = try await engine.fetchHeaders(url: "https://example.com")
```

**Automatic handling**:
- HTML: body extraction via SwiftSoup → Markdown conversion
- RSS/Atom feeds: formatted as a Markdown item list
- DocC documentation (Apple/Swift): full text fetched from render JSON API
- Bot challenges / Cloudflare interstitials: raised as `WebFetchError.challengeBlocked`
- Binary content (PDF, images, etc.): raised as `WebFetchError.binaryContent`

---

## Dependencies

| Package | Purpose |
|---|---|
| `swift-llm-client` (no-problem-dev) | `ToolSet` / `ToolSetBuilder` / `LLMTool` protocols |
| `swift-sdk` (modelcontextprotocol) | MCP protocol implementation |
| `SwiftSoup` | HTML parsing and Markdown conversion |
| `swift-http-transport` (no-problem-dev) | HTTP transport abstraction |
| `swift-structured-data` (no-problem-dev) | JSON parsing and serialization |

---

## Related

- [swift-llm-client](https://github.com/no-problem-dev/swift-llm-client) — `ToolSet` and `Tool` protocol definitions
- [swift-http-transport](https://github.com/no-problem-dev/swift-http-transport) — HTTP transport abstraction
- [Model Context Protocol](https://modelcontextprotocol.io/) — MCP specification
