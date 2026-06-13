import Testing
import Foundation
@testable import LLMMCP

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
        #expect(WebToolKit.isHTMLContent(contentType: "text/html; charset=utf-8", content: "anything"))
        #expect(WebToolKit.isHTMLContent(contentType: "application/xhtml+xml", content: "anything"))
        #expect(!WebToolKit.isHTMLContent(contentType: "application/json", content: "{}"))
        #expect(!WebToolKit.isHTMLContent(contentType: "text/plain", content: "hello"))
    }

    @Test("Detects HTML by leading tags")
    func detectsByLeadingTags() {
        #expect(WebToolKit.isHTMLContent(contentType: nil, content: "<!DOCTYPE html><html>..."))
        #expect(WebToolKit.isHTMLContent(contentType: nil, content: "<html><head>..."))
        #expect(WebToolKit.isHTMLContent(contentType: nil, content: "  <!doctype HTML>..."))
        #expect(!WebToolKit.isHTMLContent(contentType: nil, content: "{\"key\": \"value\"}"))
        #expect(!WebToolKit.isHTMLContent(contentType: nil, content: "Just plain text"))
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
}
