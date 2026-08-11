# ``LLMMCP``

Turn built-in capabilities and remote MCP servers into one flat list of tools an agent can call.

## Overview

An agent's tool list is the only thing it can act through, and it comes from two places: tools
implemented here in Swift, and tools advertised by an MCP server somewhere else. `LLMMCP`
resolves both into the same `ToolSet`, so a model cannot tell which capability came from where.

The two sources behave differently in ways that matter when you wire them up.

A ``ToolKit`` runs in this process. Its tools are available the instant the `ToolSet` is built,
there is no handshake to fail, and there is no separate sandbox — a kit has whatever access the
host process has. What bounds it is the argument you pass: `allowedPaths` for
``FileSystemToolKit``, `allowedDomains` for ``WebToolKit``. Omit them and there is no boundary.

An ``MCPServer`` runs elsewhere. Listing its tools needs a connection, and building a `ToolSet` is
synchronous, so a server enters the set as a single ``MCPServerPlaceholder`` and is expanded later
by `ToolSet.resolvingMCPServers()`. **Skip that call and the model is offered the placeholder
instead of the tools** — a placeholder throws if called, so the failure is loud rather than silent.
Connections are not pooled: every listing and every tool call opens a new one, which for a stdio
server means a fresh subprocess each time.

```swift
import LLMMCP
import LLMTool

let tools = ToolSet {
    MCPServer(
        command: "npx",
        arguments: ["-y", "@anthropic/mcp-server-filesystem", "/path/to/dir"]
    ).readOnly

    WebToolKit()
    FileSystemToolKit(allowedPaths: ["/tmp/workspace"])
    UtilityToolKit()
}

// Required whenever the set contains a server. No-op otherwise.
let resolved = try await tools.resolvingMCPServers()
```

### Restricting what a server may do

``MCPToolSelection`` filters a server's tool list before the model sees it. `.readOnly` and
`.safe` read the server's own `readOnlyHint` and `destructiveHint` annotations, which are hints —
a server that sends neither is treated as writable and non-destructive, so it survives `.safe`.
When that matters, name the tools with `.including(_:)` rather than relying on a preset.

The filter decides what is offered, not what is possible. It is not a sandbox.

### The fetch engine underneath

``WebToolKit`` is a thin adapter over `WebFetchKit`'s engine, which has no MCP or tool-calling
dependency of its own. To fetch pages from a CLI, a test, or an agent that is not using this
package, `import WebFetchKit` and use `WebFetchEngine` directly.

## Topics

### Getting started

- <doc:GettingStarted>

### Connecting to an MCP server

- ``MCPServer``
- ``MCPServerProtocol``
- ``MCPConfiguration``
- ``MCPTransport``
- ``MCPAuthorization``

### Choosing which tools reach the model

- ``MCPToolSelection``
- ``MCPToolCapabilities``

### Resolving servers into tools

- ``MCPServerPlaceholder``
- ``MCPServerWrapper``
- ``MCPTool``

### Tools that run in this process

- ``ToolKit``
- ``BuiltInTool``
- ``WebToolKit``
- ``FileSystemToolKit``
- ``ScriptToolKit``
- ``ScriptBridge``
- ``UtilityToolKit``

### Searching the web

- ``WebSearchToolKit``
- ``WebSearchProvider``
- ``WebSearchResult``
- ``BraveSearchProvider``
- ``SerperSearchProvider``
- ``FallbackSearchProvider``
- ``UnconfiguredSearchProvider``

### Rate limiting, retries and caching

- ``ResilientSearchProvider``
- ``SearchResilienceConfiguration``
- ``RateLimiter``
- ``CircuitBreaker``
- ``SearchResultCache``

### Generating images

- ``ImageGenerationToolKit``
- ``ImageGenerationProvider``
- ``ImageGenerationSize``
- ``ImageGenerationQuality``
- ``GeneratedImageData``
- ``OpenAIImageProvider``
- ``GeminiImageProvider``
- ``FalAIImageProvider``
- ``UnconfiguredImageGenerationProvider``

### Confining a session to a directory

- ``Workspace``
- ``WorkspaceSource``
- ``WorkspaceProvider``

### Errors

- ``MCPError``
- ``FileSystemToolKitError``
- ``ScriptToolKitError``
- ``WebSearchError``
- ``ImageGenerationToolError``
- ``UtilityToolKitError``
