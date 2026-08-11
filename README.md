English | [日本語](./README.ja.md)

# swift-llm-mcp

Give a Swift LLM agent things it can actually do — read files, fetch pages, search the web — from the tools built in here or from any MCP server you point it at.

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017+%20%7C%20macOS%2014+%20%7C%20Linux-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## Overview

A model can only act through the tools you hand it. This package supplies both halves of that:
a set of tools that work out of the box, and a connector that turns someone else's MCP server into
tools of the same shape. Both end up in one list you pass to the loop, so the agent cannot tell
which capability came from where.

- **Tools in the box** — fetch a page, fetch JSON, fetch headers; search the web; read, write, edit,
  move, list, tree, glob and grep files; generate an image; run JavaScript; and the small utilities
  (clock, arithmetic, UUIDs, sleep) that models otherwise get wrong
- **Connect any MCP server** — over stdio on macOS, or Streamable HTTP with bearer or custom-header
  auth
- **Narrow what a server may do** — take the read-only subset, drop the destructive operations, or
  name exactly the tools you will allow, before the model ever sees the list
- **Pages arrive as Markdown, not HTML** — navigation, scripts and styling are stripped, and long
  pages can be read in slices instead of blowing the context window in one call
- **Editing tools require reading first** — a write or edit to a file the agent has not read is
  refused, so it cannot overwrite content it never saw
- **The fetch engine stands alone** — `WebFetchKit` has no MCP or tool dependency, so you can use it
  as a plain library

## Quick Start

Build a tool set from what is built in:

```swift
import LLMMCP
import LLMTool

let tools = ToolSet {
    WebToolKit()
    FileSystemToolKit(allowedPaths: ["/path/to/workspace"])
    UtilityToolKit()
}
```

Add an external MCP server. Placeholders are resolved once, before the loop starts:

```swift
let tools = ToolSet {
    MCPServer(
        command: "npx",
        arguments: ["-y", "@anthropic/mcp-server-filesystem", "/path/to/dir"]
    ).readOnly                                   // or .safe / .including(...) / .excluding(...)

    MCPServer(
        url: URL(string: "https://mcp.example.com/mcp")!,
        authorization: .bearer("your-access-token")
    )
}

let resolved = try await tools.resolvingMCPServers()
```

Or use the fetch engine on its own, with no agent involved:

```swift
import WebFetchKit

let document = try await WebFetchEngine().fetch(url: "https://example.com")
print(document.text)          // Markdown for HTML, decoded text otherwise
print(document.wasTruncated)  // true when the body exceeded maxContentSize
```

## Documentation

[**LLMMCP**](https://no-problem-dev.github.io/swift-llm-mcp/documentation/llmmcp/) —
connecting MCP servers, the built-in tool kits, and writing your own, including
[Getting Started](https://no-problem-dev.github.io/swift-llm-mcp/documentation/llmmcp/gettingstarted/).

[**WebFetchKit**](https://no-problem-dev.github.io/swift-llm-mcp/documentation/webfetchkit/) —
the fetch engine, HTML-to-Markdown conversion, and slicing long pages.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-llm-mcp.git", .upToNextMinor(from: "0.4.0")),
],
```

```swift
.product(name: "LLMMCP", package: "swift-llm-mcp"),
// only if you want the fetch engine without the tool layer:
.product(name: "WebFetchKit", package: "swift-llm-mcp"),
```

## Requirements

- iOS 17.0+ / macOS 14.0+ / Linux — stdio MCP servers are unavailable on iOS, which cannot spawn a subprocess
- Swift 6.2+

## License

MIT — see [LICENSE](LICENSE).
