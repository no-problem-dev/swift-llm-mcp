# ``WebFetchKit``

Fetch a URL and get back text an LLM can read, with no MCP or tool-calling dependency.

## Overview

Handing a model raw HTML wastes most of its context on navigation, scripts and styling.
``WebFetchEngine`` takes a URL and returns the part worth reading: HTML becomes Markdown, RSS and
Atom become a Markdown item list, and everything else comes back as decoded text.

It knows nothing about MCP or tool calling, which is why the same engine backs `LLMMCP`'s
`WebToolKit`, the `web-fetch-probe` executable, and any agent that wants pages without the tool
layer.

```swift
import WebFetchKit

let engine = WebFetchEngine(
    allowedDomains: ["docs.swift.org", "github.com"],
    timeout: 30,
    maxContentSize: 5 * 1024 * 1024
)

let doc = try await engine.fetch(url: "https://docs.swift.org/swift-book/")
print(doc.title ?? "")
print(doc.text)
print(doc.wasTruncated)  // true when the body exceeded maxContentSize
```

### Responses that look successful but are not

Two kinds of HTTP 200 would otherwise reach the model as if they were the page, and both are
turned into errors instead.

A **bot challenge or "JavaScript required" interstitial** throws
``WebFetchError/challengeBlocked(reason:)``. Without this the model receives a reCAPTCHA notice and
treats it as the article's content. Detection is conservative: a matching page title is decisive,
but body markers count only when the extracted text is under 1500 characters, so a real article
discussing Cloudflare is not rejected.

**Binary content** — PDF, image, audio, video — throws ``WebFetchError/binaryContent(contentType:)``
rather than arriving as mojibake. The judgement is made from the Content-Type header, so a binary
body served without one is missed.

### Handling long and oversized pages

`maxContentSize` is applied after the body has been received in full. It bounds what gets decoded,
not what gets downloaded or held in memory.

The two fetch methods then diverge, deliberately. ``WebFetchEngine/fetch(url:method:headers:body:raw:)``
truncates and sets ``FetchedDocument/wasTruncated``, so an oversized page still yields its opening
section — check that flag if completeness matters.
``WebFetchEngine/fetchRawJSON(url:method:headers:body:)`` throws
``WebFetchError/contentTooLarge(size:maxSize:)`` instead, because half a JSON document cannot be parsed.

Redirects are left to the transport and no redirect limit is imposed here. The URL on the returned
document is the one that was requested, not the final one after redirects.

### Encoding

Charset is resolved in order: the Content-Type header, a `<meta charset>` declaration in the first
4 KB, UTF-8, then Shift_JIS, EUC-JP, Windows-1252, ISO-8859-1 and ASCII.

The self-validating encodings come before the permissive ones on purpose. Latin-1 and CP1252 accept
any byte sequence, so putting either first would turn every undeclared Japanese page into mojibake
instead of letting Shift_JIS claim it.

### Replacing the extractor

The default ``SwiftSoupContentExtractor`` is heuristic and can pick the wrong element. Conform to
``WebContentExtractor`` and pass your type to the engine to override it for sites you care about.

```swift
import WebFetchKit

struct CustomExtractor: WebContentExtractor {
    func extract(html: String, url: URL) throws -> ExtractedContent {
        ExtractedContent(title: "Custom", content: "...")
    }
}

let engine = WebFetchEngine(extractor: CustomExtractor())
```

Return something rather than throwing on a thin page: the engine treats a throw here as a failed
fetch, whereas returning little text is a result the caller can still judge.

## Topics

### Fetching

- ``WebFetchEngine``
- ``FetchedDocument``
- ``WebFetchHeadersResult``

### Extracting readable content

- ``WebContentExtractor``
- ``ExtractedContent``
- ``SwiftSoupContentExtractor``

### Errors

- ``WebFetchError``
