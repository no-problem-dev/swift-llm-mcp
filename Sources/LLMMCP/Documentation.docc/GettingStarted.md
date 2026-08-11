# Getting Started with LLMMCP

Assemble a tool set, decide what the agent is allowed to touch, and add tools of your own.

## Overview

This walks through the decisions the README's example glosses over: which tools to include, where
their boundaries come from, what has to happen before the set is usable, and how each kit behaves
when the model gets something wrong.

## Start with the built-in kits

Nothing here needs a subprocess or a network handshake, so a set built from kits alone is ready to
use the moment it exists.

```swift
import LLMMCP
import LLMTool

let tools = ToolSet {
    WebToolKit()
    FileSystemToolKit(allowedPaths: ["/Users/you/projects"])
    UtilityToolKit()
    ScriptToolKit(bridge: ScriptBridge(allowedPaths: ["/tmp"]))
}
```

Include ``UtilityToolKit`` in almost every set. A model has no clock, so without `get_current_time`
it will confidently invent today's date whenever the conversation touches "now" or "yesterday".

The arguments are the security model. ``FileSystemToolKit`` with no `allowedPaths` can reach every
path this process can, and ``ScriptToolKit``'s default ``ScriptBridge`` is equally unrestricted.
On iOS the app sandbox is a real boundary; on macOS it is the user's whole home directory.

## Bound a session to one directory

Rather than assembling paths by hand, hand the kit a ``Workspace``. Its initializer cannot be
configured into an unbounded state — the allowed paths are the workspace root plus whatever extras
it declares, and nothing else.

```swift
let provider = WorkspaceProvider()
let workspace = try await provider.createWorkspace(for: sessionID)

let tools = ToolSet {
    FileSystemToolKit(workspace: workspace)
}

// At the end of the session. Deletes the directory and everything in it.
await provider.removeWorkspace(for: sessionID)
```

`removeWorkspace(for:)` also works from the session id alone, so directories left behind by a
previous process run can still be reclaimed.

## What the file tools refuse to do

``FileSystemToolKit`` will not let the model destroy a file it has not seen. `write_file` on an
existing path and `edit_file` on any path both fail unless that exact path was read earlier in the
session; the error tells the model to call `read_file` first, which it generally does.

`edit_file` also refuses an `old_string` that appears more than once, unless `replace_all` is set.
That is what stops a rename from landing on the wrong occurrence.

Two limits worth knowing. `read_file` has no size cap, so a large file goes straight into the
context window — `get_file_info` first if that is a risk. And the path check is a string prefix
comparison that does not resolve symlinks, so allowing `/data` also allows `/database`, and a
symlink inside an allowed directory is followed out of it.

## Add an external MCP server

A server cannot be listed synchronously, so it enters the set as a placeholder and must be
expanded before use.

```swift
let tools = ToolSet {
    // stdio: launches a subprocess. macOS only.
    MCPServer(
        command: "/usr/local/bin/npx",
        arguments: ["-y", "@anthropic/mcp-server-filesystem", "/path/to/dir"]
    ).readOnly

    // Streamable HTTP: available everywhere.
    MCPServer(
        url: URL(string: "https://mcp.notion.com/mcp")!,
        authorization: .bearer("ntn_xxxxx")
    )
}

let resolved = try await tools.resolvingMCPServers()
```

Three things to expect:

- **`command` is not resolved through `PATH`.** Give it an absolute path.
- **Nothing connects until you resolve.** A wrong command or a dead endpoint surfaces at
  `resolvingMCPServers()`, not at construction.
- **One unreachable server loses the whole set.** Servers are contacted in order and the first
  failure propagates, so there is no partially resolved result. Resolve optional servers into a
  separate set if you want the rest to survive.

Connections are per-call. A stdio server pays process startup on every tool call and cannot keep
state between them.

## Narrow what a server may offer

```swift
let server = MCPServer(command: "/usr/local/bin/npx", arguments: [...])

server.readOnly                                   // tools annotated read-only
server.safe                                       // everything not annotated destructive
server.including("read_file", "list_directory")   // exactly these
server.excluding("delete_file")                   // everything but these
```

These replace rather than combine, so chaining two keeps only the last.

`.readOnly` and `.safe` depend on annotations the server sends. A server that omits them is treated
as writable and non-destructive, which means an unannotated destructive tool passes `.safe`. Where
that matters, name the tools explicitly.

## Configure web search

``WebSearchToolKit``'s factory methods wrap the backend in a ``ResilientSearchProvider`` by
default: results are cached for five minutes, requests are paced to one per second, the circuit
opens after five consecutive failures, and each search gets one retry.

```swift
let tools = ToolSet {
    WebSearchToolKit.brave(apiKey: braveKey)

    // Or fall through to a second engine when the first fails or finds nothing
    WebSearchToolKit.withFallback(
        primary: BraveSearchProvider(apiKey: braveKey),
        fallback: SerperSearchProvider(apiKey: serperKey, gl: "jp", hl: "ja")
    )
}
```

Two behaviours to plan around. Every error is retried, including a rejected API key, so a bad
credential is re-sent on every attempt. And each failed attempt counts separately against the
circuit breaker, so with the defaults three consecutive failing searches open the circuit, not
five. Pass `resilience: nil` to opt out entirely, or a custom
``SearchResilienceConfiguration`` to tune it.

Constructing ``WebSearchToolKit`` directly, rather than through a factory method, gives you none of
this.

## Write your own tool kit

``BuiltInTool`` takes a name, a description, a schema and a closure. The description is what the
model reads when deciding whether to call it, so write it for that reader.

```swift
import LLMMCP
import LLMTool

public struct MyToolKit: ToolKit {
    public var name: String { "my-toolkit" }

    public var tools: [any Tool] {
        [
            BuiltInTool(
                name: "my_tool",
                description: "Does something useful. Say when to use it, not just what it is.",
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

let tools = ToolSet {
    MyToolKit()
    WebToolKit()
}
```

Set the annotations. A ``BuiltInTool`` with none is classified as destructive, so it is excluded by
both the `.safe` and `.readOnly` presets — the opposite of the default an unannotated remote tool
gets.

Validate inside the closure. The schema tells the model what to send; nothing enforces it. Prefer
clamping an out-of-range value to rejecting it, as the built-in tools do, so a small mistake costs
the model one useful result rather than one wasted turn.

## Related

- ``ToolKit`` — the protocol, and what its `tools` property is expected to guarantee
- ``MCPToolSelection`` — how each preset decides
- ``ResilientSearchProvider`` — the order the four mechanisms run in
- ``Workspace`` — why the working directory and the boundary are separate
