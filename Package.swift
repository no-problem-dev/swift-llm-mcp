// swift-tools-version: 6.2
import PackageDescription

// swift-llm-mcp — MCP servers, built-in toolkits, and the `ToolKit`/`BuiltInTool`
// adapters that resolve external capabilities into a swift-llm-client `ToolSet`.
//
// Extracted from swift-llm-agent so the agent runtime depends on a focused
// tool-resolution layer rather than the whole legacy agent package.
let package = Package(
    name: "swift-llm-mcp",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LLMMCP", targets: ["LLMMCP"]),
        .library(name: "WebFetchKit", targets: ["WebFetchKit"]),
        .executable(name: "web-fetch-probe", targets: ["WebFetchProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/no-problem-dev/swift-llm-client.git", from: "3.4.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/no-problem-dev/swift-http-transport.git", from: "1.1.0"),
        .package(url: "https://github.com/no-problem-dev/swift-structured-data.git", from: "1.3.0"),
    ],
    targets: [
        // 純粋な Web フェッチ/抽出エンジン（MCP・LLMTool 非依存）
        .target(name: "WebFetchKit", dependencies: [
            .product(name: "SwiftSoup", package: "SwiftSoup"),
            .product(name: "HTTPTransport", package: "swift-http-transport"),
        ]),
        .target(name: "LLMMCP", dependencies: [
            "WebFetchKit",
            .product(name: "LLMClient", package: "swift-llm-client"),
            .product(name: "LLMTool", package: "swift-llm-client"),
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "HTTPTransport", package: "swift-http-transport"),
            .product(name: "StructuredDataCore", package: "swift-structured-data"),
            .product(name: "JSONParsing", package: "swift-structured-data"),
        ]),
        .executableTarget(name: "WebFetchProbe", dependencies: [
            "LLMMCP",
            "WebFetchKit",
            .product(name: "LLMClient", package: "swift-llm-client"),
            .product(name: "LLMTool", package: "swift-llm-client"),
            .product(name: "HTTPTransport", package: "swift-http-transport"),
        ]),
        .testTarget(name: "WebFetchKitTests", dependencies: ["WebFetchKit"]),
        .testTarget(name: "LLMMCPTests", dependencies: ["LLMMCP"]),
    ]
)
