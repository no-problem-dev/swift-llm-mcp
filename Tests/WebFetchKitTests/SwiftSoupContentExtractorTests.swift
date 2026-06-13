import Testing
import Foundation
@testable import WebFetchKit

// MARK: - DOM Cleaning Tests

@Suite("DOM Cleaning")
struct DOMCleaningTests {

    @Test("Removes script, style, nav, footer, aside, header, svg, noscript elements")
    func removesNonContentElements() throws {
        let html = """
        <html><body>
            <nav>Navigation</nav>
            <header>Header</header>
            <script>alert('x')</script>
            <style>.x { color: red; }</style>
            <svg><circle/></svg>
            <noscript>Enable JS</noscript>
            <article><p>Main content here.</p></article>
            <aside>Sidebar</aside>
            <footer>Footer</footer>
        </body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("Main content here"))
        #expect(!result.content.contains("Navigation"))
        #expect(!result.content.contains("Header"))
        #expect(!result.content.contains("alert"))
        #expect(!result.content.contains("color: red"))
        #expect(!result.content.contains("circle"))
        #expect(!result.content.contains("Enable JS"))
        #expect(!result.content.contains("Sidebar"))
        #expect(!result.content.contains("Footer"))
    }

    @Test("Removes elements with navigation/banner/complementary roles")
    func removesARIARoleElements() throws {
        let html = """
        <html><body>
            <div role="navigation">Nav</div>
            <div role="banner">Banner</div>
            <div role="complementary">Complementary</div>
            <div role="contentinfo">ContentInfo</div>
            <main><p>Real content.</p></main>
        </body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("Real content"))
        #expect(!result.content.contains("Nav"))
        #expect(!result.content.contains("Banner"))
        #expect(!result.content.contains("Complementary"))
        #expect(!result.content.contains("ContentInfo"))
    }
}

// MARK: - Readability Scoring Tests

@Suite("Readability Scoring")
struct ReadabilityScoringTests {

    @Test("Prioritizes <article> element")
    func prioritizesArticle() throws {
        let html = """
        <html><body>
            <div class="sidebar">Lots of links and navigation</div>
            <article>
                <p>This is the main article content with enough text to be meaningful.</p>
                <p>Another paragraph with more useful information for the reader.</p>
            </article>
        </body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("main article content"))
    }

    @Test("Prioritizes <main> element")
    func prioritizesMain() throws {
        let html = """
        <html><body>
            <div class="sidebar">Sidebar content</div>
            <main>
                <p>Main area content is here, with details.</p>
            </main>
        </body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("Main area content"))
    }

    @Test("Selects high-text-density div when no article/main")
    func selectsHighTextDensityDiv() throws {
        let html = """
        <html><body>
            <div class="menu">
                <a href="/1">Link 1</a><a href="/2">Link 2</a><a href="/3">Link 3</a>
            </div>
            <div class="content">
                <p>This is a substantial paragraph with real content that should score highly in readability analysis, because it contains meaningful text, commas, and multiple sentences.</p>
                <p>Another paragraph that adds to the text density of this div element.</p>
                <p>And yet another paragraph to boost the score even further with more content.</p>
            </div>
        </body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("substantial paragraph"))
    }
}

// MARK: - Markdown Conversion Tests

@Suite("Markdown Conversion")
struct MarkdownConversionTests {

    @Test("Converts headings to ATX format")
    func convertsHeadings() throws {
        let html = """
        <html><body><article>
            <h1>Title</h1>
            <h2>Subtitle</h2>
            <h3>Section</h3>
            <p>Content</p>
        </article></body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("# Title"))
        #expect(result.content.contains("## Subtitle"))
        #expect(result.content.contains("### Section"))
    }

    @Test("Converts links with absolute URLs")
    func convertsLinks() throws {
        let html = """
        <html><body><article>
            <p><a href="https://example.com/page">Absolute link</a></p>
            <p><a href="/relative">Relative link</a></p>
        </article></body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("[Absolute link](https://example.com/page)"))
        #expect(result.content.contains("[Relative link](https://example.com/relative)"))
    }

    @Test("Converts code blocks")
    func convertsCodeBlocks() throws {
        let html = """
        <html><body><article>
            <p>Use <code>inline code</code> here.</p>
            <pre><code class="language-swift">let x = 42</code></pre>
        </article></body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("`inline code`"))
        #expect(result.content.contains("```swift"))
        #expect(result.content.contains("let x = 42"))
        #expect(result.content.contains("```"))
    }

    @Test("Converts unordered lists")
    func convertsUnorderedLists() throws {
        let html = """
        <html><body><article>
            <ul>
                <li>First item</li>
                <li>Second item</li>
                <li>Third item</li>
            </ul>
        </article></body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("- First item"))
        #expect(result.content.contains("- Second item"))
        #expect(result.content.contains("- Third item"))
    }

    @Test("Converts ordered lists")
    func convertsOrderedLists() throws {
        let html = """
        <html><body><article>
            <ol>
                <li>Step one</li>
                <li>Step two</li>
            </ol>
        </article></body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("1. Step one"))
        #expect(result.content.contains("2. Step two"))
    }

    @Test("Converts tables to GFM format")
    func convertsTables() throws {
        let html = """
        <html><body><article>
            <table>
                <thead><tr><th>Name</th><th>Value</th></tr></thead>
                <tbody>
                    <tr><td>Alpha</td><td>1</td></tr>
                    <tr><td>Beta</td><td>2</td></tr>
                </tbody>
            </table>
        </article></body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("| Name | Value |"))
        #expect(result.content.contains("| --- | --- |"))
        #expect(result.content.contains("| Alpha | 1 |"))
        #expect(result.content.contains("| Beta | 2 |"))
    }

    @Test("Converts bold and italic")
    func convertsBoldItalic() throws {
        let html = """
        <html><body><article>
            <p>This is <strong>bold</strong> and <em>italic</em> text.</p>
        </article></body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("**bold**"))
        #expect(result.content.contains("*italic*"))
    }

    @Test("Converts blockquotes")
    func convertsBlockquotes() throws {
        let html = """
        <html><body><article>
            <blockquote>This is a quoted passage.</blockquote>
        </article></body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("> This is a quoted passage."))
    }

    @Test("Converts images")
    func convertsImages() throws {
        let html = """
        <html><body><article>
            <img src="https://example.com/photo.jpg" alt="A photo">
        </article></body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.content.contains("![A photo](https://example.com/photo.jpg)"))
    }
}

// MARK: - Metadata Extraction Tests

@Suite("Metadata Extraction")
struct MetadataExtractionTests {

    @Test("Extracts og:title, description, og:image, canonical")
    func extractsMetadata() throws {
        let html = """
        <html>
        <head>
            <title>Page Title</title>
            <meta property="og:title" content="OG Title">
            <meta name="description" content="A page description">
            <meta property="og:image" content="https://example.com/image.jpg">
            <link rel="canonical" href="https://example.com/canonical">
        </head>
        <body><article><p>Content.</p></article></body>
        </html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        // og:title が優先される
        #expect(result.title == "OG Title")
        #expect(result.metadata["description"] == "A page description")
        #expect(result.metadata["og:image"] == "https://example.com/image.jpg")
        #expect(result.metadata["canonical"] == "https://example.com/canonical")
    }

    @Test("Falls back to <title> when og:title missing")
    func fallsBackToTitle() throws {
        let html = """
        <html>
        <head><title>Fallback Title</title></head>
        <body><article><p>Content.</p></article></body>
        </html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)

        #expect(result.title == "Fallback Title")
    }
}

// MARK: - isHTMLContent Tests

@Suite("HTML Content Detection")
struct HTMLContentDetectionTests {

    @Test("Detects HTML by Content-Type")
    func detectsByContentType() {
        #expect(HTMLDetector.isHTML(contentType: "text/html; charset=utf-8", content: "anything"))
        #expect(HTMLDetector.isHTML(contentType: "application/xhtml+xml", content: "anything"))
        #expect(!HTMLDetector.isHTML(contentType: "application/json", content: "{}"))
        #expect(!HTMLDetector.isHTML(contentType: "text/plain", content: "hello"))
    }

    @Test("Detects HTML by leading tags")
    func detectsByLeadingTags() {
        #expect(HTMLDetector.isHTML(contentType: nil, content: "<!DOCTYPE html><html>..."))
        #expect(HTMLDetector.isHTML(contentType: nil, content: "<html><head>..."))
        #expect(HTMLDetector.isHTML(contentType: nil, content: "  <!doctype HTML>..."))
        #expect(!HTMLDetector.isHTML(contentType: nil, content: "{\"key\": \"value\"}"))
        #expect(!HTMLDetector.isHTML(contentType: nil, content: "Just plain text"))
    }
}

// MARK: - Post-processing Tests

@Suite("Post-processing")
struct PostProcessingTests {

    @Test("Compresses consecutive blank lines")
    func compressesBlankLines() {
        let input = "Line 1\n\n\n\n\nLine 2\n\n\nLine 3"
        let result = SwiftSoupContentExtractor.postProcess(input)

        #expect(result == "Line 1\n\nLine 2\n\nLine 3")
    }

    @Test("Strips trailing whitespace")
    func stripsTrailingWhitespace() {
        let input = "Line 1   \nLine 2\t\nLine 3"
        let result = SwiftSoupContentExtractor.postProcess(input)

        #expect(!result.contains("   \n"))
        #expect(!result.contains("\t\n"))
    }

    @Test("Collapses consecutive identical lines")
    func collapsesConsecutiveDuplicateLines() {
        let input = "```\n```\n```\nReal text\nReal text\n---\n---"
        let result = SwiftSoupContentExtractor.postProcess(input)
        // 連続同一行は1つに畳まれる
        #expect(result == "```\nReal text\n---")
    }

    @Test("Preserves identical table rows")
    func preservesTableRows() {
        let input = "| a | b |\n| a | b |"
        let result = SwiftSoupContentExtractor.postProcess(input)
        // テーブル行（| 始まり）は構造保持のため畳まない
        #expect(result == "| a | b |\n| a | b |")
    }
}

// MARK: - Navigational Link Block Removal Tests

@Suite("Navigational Link Block Removal")
struct NavLinkBlockTests {

    @Test("Removes short-label nav menus")
    func removesShortNavMenus() throws {
        let html = """
        <html><body>
            <div class="menu">
                <a href="/a">Home</a><a href="/b">About</a><a href="/c">Blog</a><a href="/d">Contact</a>
            </div>
            <article>
                <p>This is the genuine article body with several sentences, commas, and enough length to be the main content of the page for the reader.</p>
            </article>
        </body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)
        #expect(result.content.contains("genuine article body"))
        #expect(!result.content.contains("About"))
        #expect(!result.content.contains("Contact"))
    }

    @Test("Removes TOC by negative class even with long links")
    func removesTOCByClass() throws {
        let html = """
        <html><body>
            <ul class="toc">
                <li><a href="#s1">Section One: Introduction and Background Material</a></li>
                <li><a href="#s2">Section Two: Detailed Methodology and Approach</a></li>
                <li><a href="#s3">Section Three: Results, Discussion and Conclusions</a></li>
            </ul>
            <article><p>Real prose content lives here with meaningful sentences and details for readers to consume.</p></article>
        </body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)
        #expect(result.content.contains("Real prose content"))
        #expect(!result.content.contains("Detailed Methodology"))
    }

    @Test("Preserves long-title link lists (aggregator content)")
    func preservesAggregatorLinks() throws {
        let html = """
        <html><body>
            <div class="stories">
                <a href="/1">A deep dive into Swift concurrency and structured tasks in 2026</a>
                <a href="/2">Why content extraction for LLMs is harder than it looks</a>
                <a href="/3">Building a resilient web fetch tool with readability scoring</a>
            </div>
        </body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)
        // 記事タイトル一覧（長文リンク・ネガティブclassなし）は本文として保持
        #expect(result.content.contains("Swift concurrency"))
        #expect(result.content.contains("resilient web fetch"))
    }

    @Test("Preserves prose blocks containing some links")
    func preservesProseWithLinks() throws {
        let html = """
        <html><body><article>
            <div class="content">
                <p>This paragraph discusses <a href="/x">one topic</a> in depth, with substantial explanation and reasoning that goes well beyond mere links, including commentary, analysis, and multiple full sentences of genuine prose for the reader to absorb carefully.</p>
                <p>A second paragraph continues the discussion with <a href="/y">another reference</a> and yet more detailed prose content.</p>
            </div>
        </article></body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)
        #expect(result.content.contains("discusses"))
        #expect(result.content.contains("substantial explanation"))
    }
}

// MARK: - Thin Content Fallback Tests

@Suite("Thin Content Fallback")
struct ThinContentFallbackTests {

    @Test("Recovers table/font layout body text")
    func recoversTableLayoutText() throws {
        // td 内に本文がある旧式レイアウト（convertToMarkdown は td をスキップする）
        let longText = String(repeating: "This essay has substantial prose content. ", count: 10)
        let html = """
        <html><body>
            <table><tr><td><font>\(longText)</font></td></tr></table>
        </body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)
        // body テキストフォールバックで本文を救済できる
        #expect(result.content.contains("substantial prose content"))
        #expect(result.content.count >= 200)
    }

    @Test("Falls back to meta description for empty SPA shell")
    func fallsBackToMetaDescription() throws {
        // 本文が空の SPA シェル → og:description を最低限の本文に
        let html = """
        <html><head>
            <meta property="og:description" content="This is a meaningful page summary that an LLM can actually use as content.">
        </head><body>
            <div id="root"></div>
        </body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)
        #expect(result.content.contains("meaningful page summary"))
    }

    @Test("Keeps short but clean article without fallback contamination")
    func keepsShortCleanArticle() throws {
        // 短い正常記事 + 別所のナビ。短くても fallback で nav を混ぜない。
        let html = """
        <html><body>
            <ul class="menu"><li><a href="/a">Home</a></li><li><a href="/b">About</a></li></ul>
            <article><p>A concise but real article body.</p></article>
        </body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)
        #expect(result.content.contains("concise but real article body"))
        #expect(!result.content.contains("About"))
    }
}

// MARK: - Feed Rendering Tests

@Suite("Feed Rendering")
struct FeedRenderingTests {

    @Test("Renders RSS to item list")
    func rendersRSS() throws {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel>
            <title>My Tech Feed</title>
            <item>
                <title>First Post</title>
                <link>https://example.com/1</link>
                <pubDate>Mon, 01 Jun 2026 12:00:00 GMT</pubDate>
                <description><![CDATA[<p>Summary of the <b>first</b> post.</p>]]></description>
            </item>
            <item>
                <title>Second Post</title>
                <link>https://example.com/2</link>
                <description>Plain summary two.</description>
            </item>
        </channel></rss>
        """
        let result = try #require(FeedRenderer.render(xml: xml))
        #expect(result.title == "My Tech Feed")
        #expect(result.markdown.contains("# My Tech Feed"))
        #expect(result.markdown.contains("## First Post"))
        #expect(result.markdown.contains("https://example.com/1"))
        #expect(result.markdown.contains("Summary of the first post."))  // HTML 除去済み
        #expect(result.markdown.contains("## Second Post"))
    }

    @Test("Renders Atom with link href attribute")
    func rendersAtom() throws {
        let xml = """
        <?xml version="1.0"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <title>Atom Feed</title>
            <entry>
                <title>Entry One</title>
                <link href="https://example.com/a"/>
                <updated>2026-06-01T12:00:00Z</updated>
                <summary>An atom entry summary.</summary>
            </entry>
        </feed>
        """
        let result = try #require(FeedRenderer.render(xml: xml))
        #expect(result.markdown.contains("# Atom Feed"))
        #expect(result.markdown.contains("## Entry One"))
        #expect(result.markdown.contains("https://example.com/a"))
        #expect(result.markdown.contains("An atom entry summary."))
    }

    @Test("Detects feeds by content-type and content")
    func detectsFeeds() {
        #expect(FeedSupport.isFeed(contentType: "application/rss+xml", content: ""))
        #expect(FeedSupport.isFeed(contentType: nil, content: "<?xml version=\"1.0\"?><rss>"))
        #expect(FeedSupport.isFeed(contentType: nil, content: "<feed xmlns=\"http://www.w3.org/2005/Atom\">"))
        #expect(!FeedSupport.isFeed(contentType: "text/html", content: "<html><body>"))
    }
}

// MARK: - Challenge Detection Tests

@Suite("Challenge Detection")
struct ChallengeDetectionTests {

    @Test("Detects reCAPTCHA interstitial")
    func detectsRecaptcha() {
        let reason = ChallengeDetector.detect(
            title: "ブラウザをチェックしています - reCAPTCHA",
            text: "pubmed.ncbi.nlm.nih.gov にアクセスする前にブラウザを確認しています..."
        )
        #expect(reason != nil)
    }

    @Test("Detects Cloudflare Just a moment")
    func detectsCloudflare() {
        let reason = ChallengeDetector.detect(title: "Just a moment...", text: "Enable JavaScript and cookies to continue")
        #expect(reason != nil)
    }

    @Test("Does not flag long article mentioning captcha")
    func ignoresLongArticle() {
        let longText = String(repeating: "This article discusses how reCAPTCHA works in depth. ", count: 60)
        let reason = ChallengeDetector.detect(title: "How reCAPTCHA works", text: longText)
        #expect(reason == nil)
    }

    @Test("Does not flag normal content")
    func ignoresNormalContent() {
        #expect(ChallengeDetector.detect(title: "My Blog Post", text: "Here is some normal article content.") == nil)
    }
}

// MARK: - DocC Support Tests

@Suite("DocC Support")
struct DocCSupportTests {

    @Test("Detects Apple DocC URL and maps to render JSON")
    func mapsAppleDocCURL() throws {
        let url = try #require(URL(string: "https://developer.apple.com/documentation/swiftui/view"))
        let json = DocCSupport.renderJSONURL(for: url)
        #expect(json?.absoluteString == "https://developer.apple.com/tutorials/data/documentation/swiftui/view.json")
    }

    @Test("Detects docs.swift.org DocC URL with bundle prefix")
    func mapsSwiftOrgDocCURL() throws {
        let url = try #require(URL(string: "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/"))
        let json = DocCSupport.renderJSONURL(for: url)
        #expect(json?.absoluteString == "https://docs.swift.org/swift-book/data/documentation/the-swift-programming-language.json")
    }

    @Test("Non-DocC URL returns nil")
    func nonDocCReturnsNil() throws {
        let url = try #require(URL(string: "https://example.com/documentation/foo"))
        #expect(DocCSupport.renderJSONURL(for: url) == nil)
    }

    @Test("Renders DocC JSON to markdown")
    func rendersDocCJSON() throws {
        let json = """
        {
          "metadata": {"title": "View", "roleHeading": "Protocol"},
          "abstract": [{"type": "text", "text": "A type that represents UI."}],
          "primaryContentSections": [
            {"kind": "declarations", "declarations": [{"tokens": [{"text": "protocol "}, {"text": "View"}]}]},
            {"kind": "content", "content": [
              {"type": "heading", "level": 2, "text": "Overview"},
              {"type": "paragraph", "inlineContent": [{"type": "text", "text": "Create a "}, {"type": "codeVoice", "code": "body"}, {"type": "text", "text": " property."}]},
              {"type": "codeListing", "syntax": "swift", "code": ["struct MyView: View {", "}"]}
            ]}
          ],
          "topicSections": [{"title": "Essentials", "identifiers": ["doc://x"]}],
          "references": {"doc://x": {"title": "Body", "url": "/documentation/swiftui/view/body"}}
        }
        """.data(using: .utf8)!
        let result = try #require(DocCRenderer.render(jsonData: json, host: "developer.apple.com"))
        #expect(result.title == "View")
        #expect(result.markdown.contains("# View"))
        #expect(result.markdown.contains("*Protocol*"))
        #expect(result.markdown.contains("A type that represents UI."))
        #expect(result.markdown.contains("```swift\nprotocol View\n```"))
        #expect(result.markdown.contains("## Overview"))
        #expect(result.markdown.contains("Create a `body` property."))
        #expect(result.markdown.contains("struct MyView: View {"))
        #expect(result.markdown.contains("## Topics"))
        #expect(result.markdown.contains("[Body](https://developer.apple.com/documentation/swiftui/view/body)"))
    }
}

// MARK: - Encoding Detection Tests

@Suite("Encoding Detection")
struct EncodingDetectionTests {

    @Test("Decodes Shift_JIS declared only in HTML meta (no HTTP charset)")
    func decodesShiftJISFromMeta() throws {
        // ITmedia 等: HTTP ヘッダーに charset 無し、meta だけで Shift_JIS 宣言
        let html = "<html><head><meta charset=\"Shift_JIS\"></head><body>日本語のテスト本文</body></html>"
        let data = try #require(html.data(using: .shiftJIS))
        let decoded = EncodingDetector.decode(data, contentType: nil)
        #expect(decoded?.contains("日本語のテスト本文") == true)
    }

    @Test("Decodes Shift_JIS from meta http-equiv form")
    func decodesShiftJISFromHttpEquiv() throws {
        let html = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=Shift_JIS\"></head><body>東京</body></html>"
        let data = try #require(html.data(using: .shiftJIS))
        let decoded = EncodingDetector.decode(data, contentType: nil)
        #expect(decoded?.contains("東京") == true)
    }

    @Test("HTTP header charset takes priority")
    func httpHeaderPriority() throws {
        let html = "<html><body>café</body></html>"
        let data = try #require(html.data(using: .utf8))
        let decoded = EncodingDetector.decode(data, contentType: "text/html; charset=UTF-8")
        #expect(decoded?.contains("café") == true)
    }

    @Test("UTF-8 page without any charset declaration")
    func utf8WithoutDeclaration() throws {
        let html = "<html><body>これは UTF-8 の本文です</body></html>"
        let data = try #require(html.data(using: .utf8))
        let decoded = EncodingDetector.decode(data, contentType: nil)
        #expect(decoded?.contains("これは UTF-8 の本文です") == true)
    }

    @Test("sniffMetaCharset extracts declared charset")
    func sniffsMetaCharset() throws {
        let html = "<!doctype html><meta charset=\"euc-jp\">"
        let data = try #require(html.data(using: .ascii))
        #expect(EncodingDetector.sniffMetaCharset(data) == "euc-jp")
    }
}

// MARK: - Tracking Param Stripping Tests

@Suite("Tracking Param Stripping")
struct TrackingParamTests {

    @Test("Strips utm_ and known tracking params")
    func stripsTracking() {
        let input = "https://example.com/page?id=42&utm_source=news&utm_campaign=x&gclid=abc&fbclid=def"
        let result = SwiftSoupContentExtractor.stripTrackingParams(input)
        #expect(result.contains("id=42"))
        #expect(!result.contains("utm_source"))
        #expect(!result.contains("utm_campaign"))
        #expect(!result.contains("gclid"))
        #expect(!result.contains("fbclid"))
    }

    @Test("Leaves clean URLs untouched")
    func leavesCleanURLs() {
        let input = "https://example.com/page?q=swift&page=2"
        #expect(SwiftSoupContentExtractor.stripTrackingParams(input) == input)
    }

    @Test("Drops query entirely when only tracking params")
    func dropsQueryWhenAllTracking() {
        let input = "https://example.com/page?utm_source=x&utm_medium=y"
        let result = SwiftSoupContentExtractor.stripTrackingParams(input)
        #expect(!result.contains("?"))
        #expect(result.hasPrefix("https://example.com/page"))
    }

    @Test("Links in extracted content have tracking stripped")
    func linksStripTracking() throws {
        let html = """
        <html><body><article>
            <p>Read <a href="https://example.com/post?utm_source=feed&id=7">this article</a> with enough surrounding prose to be selected as the main content of the page for readability.</p>
        </article></body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)
        #expect(result.content.contains("id=7"))
        #expect(!result.content.contains("utm_source"))
    }
}

// MARK: - Empty Code Block Tests

@Suite("Empty Code Block Suppression")
struct EmptyCodeBlockTests {

    @Test("Suppresses empty pre/code blocks")
    func suppressesEmptyCodeBlocks() throws {
        let html = """
        <html><body><article>
            <p>Intro text that is long enough to be selected as the main content here.</p>
            <pre><code></code></pre>
            <pre>   </pre>
            <p>More substantial body text follows after the empty code blocks above.</p>
        </article></body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)
        // 空コードブロックの ``` フェンスが出力されない
        #expect(!result.content.contains("```"))
        #expect(result.content.contains("Intro text"))
    }

    @Test("Keeps non-empty code blocks")
    func keepsNonEmptyCodeBlocks() throws {
        let html = """
        <html><body><article>
            <p>Some intro paragraph with enough length to anchor the readability score.</p>
            <pre><code class="language-swift">let x = 1</code></pre>
        </article></body></html>
        """
        let extractor = SwiftSoupContentExtractor()
        let result = try extractor.extract(html: html, url: URL(string: "https://example.com")!)
        #expect(result.content.contains("```swift"))
        #expect(result.content.contains("let x = 1"))
    }
}
