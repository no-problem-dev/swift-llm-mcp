import Foundation

// MARK: - Corpus

/// Web フェッチツールの安定性を計測するための静的 URL コーパス。
///
/// 各エントリは「カテゴリ」と「期待される結末」を持つ。期待結末と実際の
/// 分類結果を突き合わせることで、ツールが仕様通りに振る舞ったか／想定外の
/// 壊れ方をしたかを機械判定できる。
enum ProbeCategory: String, CaseIterable, Codable {
    case staticContent = "静的コンテンツ/Wiki"
    case news = "ニュース大手"
    case officialDocs = "公式ドキュメント"
    case github = "GitHub"
    case jsonAPI = "JSON API"
    case binary = "バイナリ(PDF/画像)"
    case spa = "SPA(JS描画)"
    case botProtected = "Bot保護(CF/Akamai)"
    case japanese = "日本語サイト"
    case redirect = "リダイレクト/短縮URL"
    case largePage = "巨大ページ"
    case negativeControl = "陰性対照(404/不正)"
    // 拡張カテゴリ
    case japaneseNews = "日系ニュース/メディア"
    case japaneseEC = "日系EC/サービス"
    case japaneseGov = "日系 政府/公共/金融"
    case japaneseCommunity = "日系 コミュニティ/ブログ/レシピ"
    case feedXML = "RSS/Atom/XML フィード"
    case plainText = "プレーンテキスト/RFC/設定"
    case i18nEncoding = "多言語エンコーディング"
    case academicForum = "学術/フォーラム/Q&A"
    case docc = "DocC(Apple/Swift JS描画)"
    case paywall = "ペイウォール/ブログ基盤"
}

/// このコーパス内で「成功すべき/失敗すべき」の事前期待。
/// classifier が出す ``FailureLayer`` と突き合わせる。
enum ExpectedOutcome: String, Codable {
    /// 本文が抽出できて成功するべき
    case readableSuccess
    /// 2xx だが本文が薄い可能性が高い（SPA / paywall）。劣化検出の対象
    case thinContentLikely
    /// 4xx でブロックされる可能性（bot 検出 / paywall）
    case httpBlockedLikely
    /// 404 など not found
    case notFound
    /// DNS / 接続レベルの失敗
    case networkError
    /// URL 検証で弾かれるべき
    case invalidURL
    /// バイナリで contentTooLarge になりうる
    case binaryLikely
    /// JSON として取得できる（fetch でも raw テキストで返る）
    case jsonSuccess
}

struct CorpusEntry: Codable {
    let url: String
    let category: ProbeCategory
    let expected: ExpectedOutcome
    /// 巨大ページ判定など補足メモ（任意）
    var note: String? = nil
}

enum Corpus {
    static let entries: [CorpusEntry] = [
        // MARK: 静的コンテンツ / Wiki (ベースライン: 成功すべき)
        .init(url: "https://en.wikipedia.org/wiki/Swift_(programming_language)", category: .staticContent, expected: .readableSuccess),
        .init(url: "https://ja.wikipedia.org/wiki/Swift_(プログラミング言語)", category: .staticContent, expected: .readableSuccess),
        .init(url: "https://developer.mozilla.org/en-US/docs/Web/HTTP", category: .staticContent, expected: .readableSuccess),
        .init(url: "https://example.com", category: .staticContent, expected: .readableSuccess),
        .init(url: "https://www.gutenberg.org/files/1342/1342-h/1342-h.htm", category: .staticContent, expected: .readableSuccess, note: "Pride and Prejudice full HTML"),
        .init(url: "https://news.ycombinator.com", category: .staticContent, expected: .readableSuccess),
        .init(url: "https://lobste.rs", category: .staticContent, expected: .readableSuccess),
        .init(url: "https://martinfowler.com/articles/microservices.html", category: .staticContent, expected: .readableSuccess),
        .init(url: "https://blog.codinghorror.com", category: .staticContent, expected: .readableSuccess),
        .init(url: "https://www.paulgraham.com/greatwork.html", category: .staticContent, expected: .readableSuccess, note: "minimal markup"),

        // MARK: ニュース大手 (paywall / bot ブロックが混在)
        .init(url: "https://www.nytimes.com", category: .news, expected: .httpBlockedLikely),
        .init(url: "https://www.bbc.com/news", category: .news, expected: .readableSuccess),
        .init(url: "https://www.theguardian.com/international", category: .news, expected: .readableSuccess),
        .init(url: "https://www.reuters.com", category: .news, expected: .httpBlockedLikely, note: "Akamai bot protection"),
        .init(url: "https://www.bloomberg.com", category: .news, expected: .httpBlockedLikely),
        .init(url: "https://www.nikkei.com", category: .news, expected: .thinContentLikely),
        .init(url: "https://www3.nhk.or.jp/news/", category: .news, expected: .readableSuccess),
        .init(url: "https://techcrunch.com", category: .news, expected: .readableSuccess),
        .init(url: "https://arstechnica.com", category: .news, expected: .readableSuccess),
        .init(url: "https://www.wsj.com", category: .news, expected: .httpBlockedLikely),

        // MARK: 公式ドキュメント
        .init(url: "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/", category: .officialDocs, expected: .readableSuccess),
        .init(url: "https://docs.python.org/3/tutorial/index.html", category: .officialDocs, expected: .readableSuccess),
        .init(url: "https://nodejs.org/api/fs.html", category: .officialDocs, expected: .readableSuccess, note: "large"),
        .init(url: "https://kubernetes.io/docs/concepts/", category: .officialDocs, expected: .readableSuccess),
        .init(url: "https://www.rust-lang.org/learn", category: .officialDocs, expected: .readableSuccess),
        .init(url: "https://react.dev/learn", category: .officialDocs, expected: .thinContentLikely, note: "React-rendered docs"),
        .init(url: "https://tailwindcss.com/docs/installation", category: .officialDocs, expected: .readableSuccess),
        .init(url: "https://www.postgresql.org/docs/current/index.html", category: .officialDocs, expected: .readableSuccess),

        // MARK: GitHub (HTML vs raw)
        .init(url: "https://github.com/apple/swift", category: .github, expected: .readableSuccess),
        .init(url: "https://github.com/apple/swift/blob/main/README.md", category: .github, expected: .readableSuccess),
        .init(url: "https://raw.githubusercontent.com/apple/swift/main/README.md", category: .github, expected: .readableSuccess, note: "raw markdown, not HTML"),
        .init(url: "https://github.com/scinfu/SwiftSoup/blob/master/README.md", category: .github, expected: .readableSuccess),
        .init(url: "https://gist.github.com/defunkt/2059", category: .github, expected: .readableSuccess),
        .init(url: "https://github.com/this-org-should-not-exist-xyz/nope", category: .github, expected: .notFound),
        .init(url: "https://api.github.com/repos/apple/swift", category: .github, expected: .jsonSuccess),
        .init(url: "https://github.com/torvalds/linux/blob/master/MAINTAINERS", category: .github, expected: .readableSuccess, note: "very large file"),

        // MARK: JSON API (公開・キー不要)
        .init(url: "https://httpbin.org/json", category: .jsonAPI, expected: .jsonSuccess),
        .init(url: "https://api.github.com", category: .jsonAPI, expected: .jsonSuccess),
        .init(url: "https://jsonplaceholder.typicode.com/posts/1", category: .jsonAPI, expected: .jsonSuccess),
        .init(url: "https://api.publicapis.org/entries", category: .jsonAPI, expected: .jsonSuccess),
        .init(url: "https://catfact.ninja/fact", category: .jsonAPI, expected: .jsonSuccess),
        .init(url: "https://www.boredapi.com/api/activity", category: .jsonAPI, expected: .jsonSuccess),

        // MARK: バイナリ (PDF / 画像 / 圧縮)
        .init(url: "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf", category: .binary, expected: .binaryLikely, note: "small PDF, P0-b で拒否されるべき"),
        .init(url: "https://www.orimi.com/pdf-test.pdf", category: .binary, expected: .binaryLikely),
        .init(url: "https://upload.wikimedia.org/wikipedia/commons/3/3f/Fronalpstock_big.jpg", category: .binary, expected: .binaryLikely, note: "large JPEG"),
        .init(url: "https://file-examples.com/storage/fe44ae1a5b66b9d7f5e2b1e/2017/10/file_example_PNG_3MB.png", category: .binary, expected: .binaryLikely),
        .init(url: "https://www.learningcontainer.com/wp-content/uploads/2020/05/sample-mp4-file.mp4", category: .binary, expected: .binaryLikely, note: "video"),
        .init(url: "https://research.nhm.org/pdfs/10840/10840.pdf", category: .binary, expected: .binaryLikely, note: "research PDF"),
        .init(url: "https://www.africau.edu/images/default/sample.pdf", category: .binary, expected: .binaryLikely, note: "tiny PDF, P0-b で拒否されるべき"),
        .init(url: "https://filesamples.com/samples/document/pdf/sample3.pdf", category: .binary, expected: .binaryLikely),

        // MARK: SPA (JS 描画 → 2xx だが本文薄い可能性)
        .init(url: "https://twitter.com/jack", category: .spa, expected: .thinContentLikely),
        .init(url: "https://x.com", category: .spa, expected: .thinContentLikely),
        .init(url: "https://www.instagram.com", category: .spa, expected: .thinContentLikely),
        .init(url: "https://web.dev", category: .spa, expected: .thinContentLikely),
        .init(url: "https://app.netlify.com", category: .spa, expected: .thinContentLikely),
        .init(url: "https://vercel.com", category: .spa, expected: .thinContentLikely),
        .init(url: "https://linear.app", category: .spa, expected: .thinContentLikely),
        .init(url: "https://www.notion.so", category: .spa, expected: .thinContentLikely),
        .init(url: "https://discord.com", category: .spa, expected: .thinContentLikely),
        .init(url: "https://www.figma.com", category: .spa, expected: .thinContentLikely),

        // MARK: Bot 保護 (Cloudflare / Akamai / PerimeterX)
        .init(url: "https://www.cloudflare.com", category: .botProtected, expected: .readableSuccess, note: "CF own site usually OK"),
        .init(url: "https://www.g2.com", category: .botProtected, expected: .httpBlockedLikely),
        .init(url: "https://www.crunchbase.com", category: .botProtected, expected: .httpBlockedLikely),
        .init(url: "https://www.indeed.com", category: .botProtected, expected: .httpBlockedLikely),
        .init(url: "https://www.glassdoor.com", category: .botProtected, expected: .httpBlockedLikely),
        .init(url: "https://www.zillow.com", category: .botProtected, expected: .httpBlockedLikely),
        .init(url: "https://www.amazon.com", category: .botProtected, expected: .thinContentLikely),
        .init(url: "https://www.ticketmaster.com", category: .botProtected, expected: .httpBlockedLikely),

        // MARK: 日本語サイト (encoding バリエーション)
        .init(url: "https://www.aozora.gr.jp/cards/000148/files/773_14560.html", category: .japanese, expected: .readableSuccess, note: "Shift_JIS classic"),
        .init(url: "https://www.yahoo.co.jp", category: .japanese, expected: .readableSuccess),
        .init(url: "https://www.asahi.com", category: .japanese, expected: .thinContentLikely),
        .init(url: "https://qiita.com/trend", category: .japanese, expected: .readableSuccess),
        .init(url: "https://zenn.dev", category: .japanese, expected: .readableSuccess),
        .init(url: "https://b.hatena.ne.jp/hotentry/it", category: .japanese, expected: .readableSuccess),
        .init(url: "https://www.itmedia.co.jp", category: .japanese, expected: .readableSuccess),
        .init(url: "https://srad.jp", category: .japanese, expected: .readableSuccess, note: "EUC-JP legacy possible"),
        .init(url: "https://www.aozora.gr.jp", category: .japanese, expected: .readableSuccess),
        .init(url: "https://dev.classmethod.jp", category: .japanese, expected: .readableSuccess),

        // MARK: リダイレクト / 短縮 URL (URLSession 追従)
        .init(url: "https://httpbin.org/redirect/3", category: .redirect, expected: .jsonSuccess, note: "3-hop redirect to /get"),
        .init(url: "https://httpbin.org/absolute-redirect/2", category: .redirect, expected: .jsonSuccess),
        .init(url: "https://bit.ly/3xExample", category: .redirect, expected: .notFound, note: "likely dead short link"),
        .init(url: "http://example.com", category: .redirect, expected: .readableSuccess, note: "http→https upgrade"),
        .init(url: "https://t.co/example", category: .redirect, expected: .notFound),
        .init(url: "https://httpbin.org/status/301", category: .redirect, expected: .notFound, note: "redirect to nowhere"),

        // MARK: 巨大ページ (truncation 挙動)
        .init(url: "https://en.wikipedia.org/wiki/List_of_Unicode_characters", category: .largePage, expected: .readableSuccess, note: "huge table"),
        .init(url: "https://www.w3.org/TR/html52/", category: .largePage, expected: .readableSuccess, note: "huge spec single page"),
        .init(url: "https://html.spec.whatwg.org/", category: .largePage, expected: .binaryLikely, note: ">10MB single page → may exceed maxContentSize"),
        .init(url: "https://en.wikipedia.org/wiki/United_States", category: .largePage, expected: .readableSuccess),

        // MARK: 陰性対照 (確実に失敗すべき)
        .init(url: "https://httpbin.org/status/404", category: .negativeControl, expected: .notFound),
        .init(url: "https://httpbin.org/status/403", category: .negativeControl, expected: .httpBlockedLikely),
        .init(url: "https://httpbin.org/status/500", category: .negativeControl, expected: .httpBlockedLikely, note: "5xx server error"),
        .init(url: "https://httpbin.org/status/429", category: .negativeControl, expected: .httpBlockedLikely, note: "rate limit"),
        .init(url: "https://this-domain-truly-does-not-exist-abcxyz123.com", category: .negativeControl, expected: .networkError, note: "DNS failure"),
        .init(url: "https://expired.badssl.com", category: .negativeControl, expected: .networkError, note: "TLS cert expired"),
        .init(url: "https://self-signed.badssl.com", category: .negativeControl, expected: .networkError, note: "self-signed TLS"),
        .init(url: "ftp://ftp.example.com/file.txt", category: .negativeControl, expected: .invalidURL, note: "unsupported scheme"),
        .init(url: "not-a-valid-url", category: .negativeControl, expected: .invalidURL),
        .init(url: "https://httpbin.org/delay/30", category: .negativeControl, expected: .networkError, note: "exceeds probe timeout → timed out"),

        // MARK: 日系ニュース/メディア
        .init(url: "https://mainichi.jp", category: .japaneseNews, expected: .readableSuccess),
        .init(url: "https://www.yomiuri.co.jp", category: .japaneseNews, expected: .readableSuccess),
        .init(url: "https://www.sankei.com", category: .japaneseNews, expected: .readableSuccess),
        .init(url: "https://www.jiji.com", category: .japaneseNews, expected: .readableSuccess),
        .init(url: "https://toyokeizai.net", category: .japaneseNews, expected: .readableSuccess),
        .init(url: "https://diamond.jp", category: .japaneseNews, expected: .readableSuccess),
        .init(url: "https://bunshun.jp", category: .japaneseNews, expected: .readableSuccess),
        .init(url: "https://newspicks.com", category: .japaneseNews, expected: .thinContentLikely, note: "SPA"),
        .init(url: "https://www.watch.impress.co.jp", category: .japaneseNews, expected: .readableSuccess),
        .init(url: "https://gigazine.net", category: .japaneseNews, expected: .readableSuccess),

        // MARK: 日系EC/サービス
        .init(url: "https://www.amazon.co.jp", category: .japaneseEC, expected: .thinContentLikely),
        .init(url: "https://www.rakuten.co.jp", category: .japaneseEC, expected: .readableSuccess),
        .init(url: "https://shopping.yahoo.co.jp", category: .japaneseEC, expected: .readableSuccess),
        .init(url: "https://jp.mercari.com", category: .japaneseEC, expected: .thinContentLikely, note: "SPA"),
        .init(url: "https://zozo.jp", category: .japaneseEC, expected: .readableSuccess),
        .init(url: "https://kakaku.com", category: .japaneseEC, expected: .readableSuccess),
        .init(url: "https://www.yodobashi.com", category: .japaneseEC, expected: .thinContentLikely),
        .init(url: "https://tabelog.com", category: .japaneseEC, expected: .readableSuccess),
        .init(url: "https://www.jalan.net", category: .japaneseEC, expected: .readableSuccess),
        .init(url: "https://suumo.jp", category: .japaneseEC, expected: .readableSuccess),

        // MARK: 日系 政府/公共/金融
        .init(url: "https://www.kantei.go.jp", category: .japaneseGov, expected: .readableSuccess, note: "首相官邸"),
        .init(url: "https://www.soumu.go.jp", category: .japaneseGov, expected: .readableSuccess, note: "総務省"),
        .init(url: "https://www.nta.go.jp", category: .japaneseGov, expected: .readableSuccess, note: "国税庁"),
        .init(url: "https://www.jma.go.jp/jma/index.html", category: .japaneseGov, expected: .readableSuccess, note: "気象庁"),
        .init(url: "https://www.mhlw.go.jp", category: .japaneseGov, expected: .readableSuccess, note: "厚労省"),
        .init(url: "https://www.boj.or.jp", category: .japaneseGov, expected: .readableSuccess, note: "日本銀行"),
        .init(url: "https://www.jpx.co.jp", category: .japaneseGov, expected: .readableSuccess, note: "東証"),
        .init(url: "https://www.e-stat.go.jp", category: .japaneseGov, expected: .thinContentLikely, note: "統計 SPA 疑い"),

        // MARK: 日系 コミュニティ/ブログ/レシピ
        .init(url: "https://qiita.com/tags/swift", category: .japaneseCommunity, expected: .readableSuccess),
        .init(url: "https://note.com", category: .japaneseCommunity, expected: .thinContentLikely),
        .init(url: "https://connpass.com", category: .japaneseCommunity, expected: .readableSuccess),
        .init(url: "https://ameblo.jp", category: .japaneseCommunity, expected: .readableSuccess),
        .init(url: "https://oshiete.goo.ne.jp", category: .japaneseCommunity, expected: .readableSuccess, note: "教えて!goo"),
        .init(url: "https://detail.chiebukuro.yahoo.co.jp", category: .japaneseCommunity, expected: .readableSuccess, note: "知恵袋"),
        .init(url: "https://cookpad.com", category: .japaneseCommunity, expected: .readableSuccess, note: "レシピ"),
        .init(url: "https://www.kurashiru.com", category: .japaneseCommunity, expected: .thinContentLikely, note: "レシピ SPA"),
        .init(url: "https://delishkitchen.tv", category: .japaneseCommunity, expected: .thinContentLikely, note: "レシピ"),
        .init(url: "https://www.pixiv.net", category: .japaneseCommunity, expected: .thinContentLikely, note: "SPA"),
        .init(url: "https://www.nintendo.co.jp", category: .japaneseCommunity, expected: .readableSuccess, note: "任天堂"),
        .init(url: "https://kakuyomu.jp", category: .japaneseCommunity, expected: .readableSuccess, note: "小説投稿"),

        // MARK: RSS/Atom/XML フィード（非 HTML → 生テキスト返却）
        .init(url: "https://news.ycombinator.com/rss", category: .feedXML, expected: .readableSuccess, note: "RSS"),
        .init(url: "https://feeds.bbci.co.uk/news/rss.xml", category: .feedXML, expected: .readableSuccess, note: "RSS"),
        .init(url: "https://b.hatena.ne.jp/hotentry/it.rss", category: .feedXML, expected: .readableSuccess, note: "はてブ RSS"),
        .init(url: "https://www.reddit.com/r/swift/.rss", category: .feedXML, expected: .readableSuccess, note: "Atom"),
        .init(url: "https://zenn.dev/feed", category: .feedXML, expected: .readableSuccess, note: "Zenn RSS"),
        .init(url: "https://www.google.com/sitemap.xml", category: .feedXML, expected: .readableSuccess, note: "sitemap"),

        // MARK: プレーンテキスト/RFC/設定
        .init(url: "https://www.rfc-editor.org/rfc/rfc2616.txt", category: .plainText, expected: .readableSuccess, note: "RFC plain text large"),
        .init(url: "https://www.google.com/robots.txt", category: .plainText, expected: .readableSuccess),
        .init(url: "https://raw.githubusercontent.com/torvalds/linux/master/README", category: .plainText, expected: .readableSuccess),
        .init(url: "https://www.gnu.org/licenses/gpl-3.0.txt", category: .plainText, expected: .readableSuccess),
        .init(url: "https://raw.githubusercontent.com/apple/swift-evolution/main/proposals/0001-keywords-as-argument-labels.md", category: .plainText, expected: .readableSuccess, note: "raw markdown"),

        // MARK: 多言語エンコーディング
        .init(url: "https://www.people.com.cn", category: .i18nEncoding, expected: .readableSuccess, note: "中国語(GB2312/UTF-8)"),
        .init(url: "https://www.naver.com", category: .i18nEncoding, expected: .readableSuccess, note: "韓国語(EUC-KR/UTF-8)"),
        .init(url: "https://lenta.ru", category: .i18nEncoding, expected: .readableSuccess, note: "ロシア語 Cyrillic"),
        .init(url: "https://www.lemonde.fr", category: .i18nEncoding, expected: .thinContentLikely, note: "仏語 paywall 疑い"),
        .init(url: "https://www.spiegel.de", category: .i18nEncoding, expected: .readableSuccess, note: "独語"),
        .init(url: "https://www.aljazeera.net", category: .i18nEncoding, expected: .readableSuccess, note: "アラビア語 RTL"),
        .init(url: "https://zh.wikipedia.org/wiki/Swift", category: .i18nEncoding, expected: .readableSuccess, note: "中国語 Wikipedia"),
        .init(url: "https://ko.wikipedia.org/wiki/스위프트_(프로그래밍_언어)", category: .i18nEncoding, expected: .readableSuccess, note: "韓国語 Wikipedia + 非ASCII URL"),

        // MARK: 学術/フォーラム/Q&A
        .init(url: "https://arxiv.org/abs/1706.03762", category: .academicForum, expected: .readableSuccess, note: "Attention is all you need"),
        .init(url: "https://pubmed.ncbi.nlm.nih.gov/33024307/", category: .academicForum, expected: .readableSuccess),
        .init(url: "https://stackoverflow.com/questions/24002092/how-to-deal-with-swift", category: .academicForum, expected: .readableSuccess),
        .init(url: "https://old.reddit.com/r/swift", category: .academicForum, expected: .readableSuccess, note: "old reddit SSR"),
        .init(url: "https://www.reddit.com/r/swift", category: .academicForum, expected: .thinContentLikely, note: "new reddit SPA"),
        .init(url: "https://news.ycombinator.com/item?id=1", category: .academicForum, expected: .readableSuccess),

        // MARK: DocC(Apple/Swift JS描画) — HTML vs JSON API
        .init(url: "https://developer.apple.com/documentation/swiftui/view", category: .docc, expected: .thinContentLikely, note: "DocC HTML → og:desc のみ"),
        .init(url: "https://developer.apple.com/documentation/swiftui", category: .docc, expected: .thinContentLikely, note: "DocC HTML"),
        .init(url: "https://developer.apple.com/tutorials/data/documentation/swiftui/view.json", category: .docc, expected: .readableSuccess, note: "DocC JSON API(全文取得可)"),
        .init(url: "https://docs.swift.org/swift-book/data/documentation/the-swift-programming-language.json", category: .docc, expected: .readableSuccess, note: "Swift Book DocC JSON"),

        // MARK: ペイウォール/ブログ基盤
        .init(url: "https://medium.com/@apple", category: .paywall, expected: .thinContentLikely, note: "Medium paywall/SPA"),
        .init(url: "https://dev.to", category: .paywall, expected: .readableSuccess),
        .init(url: "https://substack.com", category: .paywall, expected: .thinContentLikely),
        .init(url: "https://www.economist.com", category: .paywall, expected: .httpBlockedLikely),
    ]
}
