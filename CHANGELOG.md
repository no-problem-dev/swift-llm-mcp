# Changelog

## [Unreleased]

### Changed

- **BREAKING** — raised the swift-http-transport pin to 2.0.0 and the swift-llm-client pin to
  5.0.0. The http-transport bump is breaking here because `HTTPTransport` is a *public* dependency:
  it appears in the initializers of `OpenAIImageProvider`, `FalAIImageProvider` and
  `GeminiImageProvider`, and in `WebFetchEngine.transport`. A caller supplying its own transport
  has to be on 2.x. The llm-client bump is internal and changes nothing a caller can see.
- Builds and tests on Linux, verified against `swift:6.2` in Docker. What blocked the build was the
  checked-in `Package.resolved`, which held swift-structured-data at 3.0.0 — the release before
  that package's Linux fix, still reaching `CFGetTypeID`. Raised to 3.0.1. Two capabilities were
  then found switched off on Linux rather than absent from it, and both are now on.
- **stdio MCP servers now run on Linux.** `MCPTransport.stdio` and `ProcessTransport` were behind
  `#if os(macOS)`, but they use only `Process` and `FileHandle.availableData`, which Linux
  Foundation has — the gate excluded a platform that could always have run them. It now excludes
  iOS, which genuinely cannot spawn a subprocess. This adds a case to `MCPTransport` on Linux, so
  an exhaustive `switch` over it in Linux-only code now needs the `.stdio` case.
- Charset names in `WebFetchKit` resolve through a table of the WHATWG Encoding Standard's labels
  instead of `CFStringConvertIANACharSetNameToEncoding`. The old code returned `nil` for any name
  outside a list of twelve when off Apple platforms, so a Linux build reported Big5, GB18030,
  EUC-KR, KOI8-R and most of ISO-8859 as undecodable although Foundation can decode all of them.
  Both platforms now answer the same, and the label set is the one browsers use.

### Fixed

- The long-message transport test passed its 300 KB payload as a command-line argument, which Linux
  refuses — a single argument is capped at 128 KiB there. The child process now generates the
  payload, so the test measures the read buffer rather than the platform's `argv` limit.

## [0.3.0] - 2026-08-11

### Fixed

- **The path sandbox was a string prefix.** Allowing `/data` therefore also allowed `/database`,
  and `standardizedFileURL` collapses `..` without resolving symlinks, so a link inside an allowed
  directory reached outside it. This is the boundary for a toolkit an LLM drives. One
  `PathBoundary` now serves both toolkits: containment is on component boundaries, and the
  canonical path is walked down from `/` one component at a time so `..` resolves *after* symlinks
  — a purely lexical collapse would let `link/../secret` name a sibling of the link rather than of
  its target. Allowed roots are canonicalized too, so a root reached through `/tmp` still matches.
- **`ios.fetch` had no host allowlist**, so a model-authored script could reach any host, including
  one on localhost. Matching is on DNS labels: `example.com` admits `api.example.com` and refuses
  both `notexample.com` and `example.com.evil.net`.
- **A tool schema that failed to decode became an empty object**, so the model was told the tool
  takes no arguments and called it wrongly. `listTools()` now fails whole rather than partially — a
  short list is otherwise indistinguishable from a complete one.
- `pendingData` had no bound, so a server writing without a newline could take the host to OOM.
  `read_file` had no size cap at all; a refused read also used to mark the path as read-tracked,
  which let a subsequent write through.


## [0.2.0] - 2026-08-11

### Changed

- Raised the swift-llm-client pin to 4.0.0 and the swift-structured-data pin to 3.0.0. Neither
  changes this package's own API: llm-client 4.0.0 alters protocol *requirement* signatures, which
  affects types that conform to them, not code that calls them.


## [0.1.2] - 2026-07-19

See [GitHub Releases](../../releases) for changes up to and including this version.
