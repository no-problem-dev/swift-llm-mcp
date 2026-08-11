import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LLMClient
import LLMTool

// MARK: - MCPServerProtocol

/// A remote or subprocess MCP server whose tools can be listed and called.
///
/// Conform to it to stand in for a real server in tests, or to front a tool source that is
/// not an MCP server at all. ``MCPServer`` is the built-in conformance.
///
/// ```swift
/// let tools = ToolSet {
///     MCPServer(command: "npx", arguments: ["-y", "@anthropic/mcp-server-filesystem", "/path"])
///         .readOnly
///
///     MCPServer(url: URL(string: "http://localhost:8080")!)
///         .including("tool1", "tool2")
/// }
/// ```
public protocol MCPServerProtocol: Sendable {
    /// Name used to identify this server in errors and in placeholder tool names.
    var serverName: String { get }

    var configuration: MCPConfiguration { get }

    /// Which of the server's tools reach the model. Applied by ``getFilteredTools()``, not by ``fetchTools()``.
    var toolSelection: MCPToolSelection { get }

    /// Connects and returns every tool the server advertises, unfiltered.
    ///
    /// Call ``getFilteredTools()`` instead unless you want to see what the filter excludes —
    /// this method ignores ``toolSelection``.
    ///
    /// - Throws: A connection or listing error from the underlying transport.
    func fetchTools() async throws -> [MCPTool]

    /// Calls one tool by name.
    ///
    /// - Parameters:
    ///   - toolName: Tool to call. An unknown name is rejected by the server, not here.
    ///   - arguments: Arguments as a JSON object. Empty data means no arguments.
    /// - Throws: A connection error, or whatever the server reports.
    func executeTool(named toolName: String, arguments: Data) async throws -> ToolResult
}

// MARK: - MCPAuthorization

/// How to authenticate against an HTTP MCP server.
///
/// Ignored by the stdio transport, which inherits the parent process environment instead.
/// The token is held in memory for the lifetime of the ``MCPServer`` value and is sent on
/// every request, including redirects the transport follows.
///
/// ```swift
/// MCPServer(url: url, authorization: .bearer("your-access-token"))
/// MCPServer(url: url, authorization: .header("X-API-Key", "your-api-key"))
/// ```
public enum MCPAuthorization: Sendable {
    /// Sends `Authorization: Bearer <token>`, the OAuth 2.1 form most hosted servers expect.
    case bearer(String)

    /// Sends one header with the given name and value.
    case header(String, String)

    /// Sends several headers. Iteration order is unspecified, so do not use it for duplicate names.
    case headers([String: String])

    case none

    /// Writes this scheme's headers onto a request, replacing any existing value for the same name.
    internal func apply(to request: inout URLRequest) {
        switch self {
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .header(let name, let value):
            request.setValue(value, forHTTPHeaderField: name)
        case .headers(let headers):
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
        case .none:
            break
        }
    }
}

// MARK: - MCPConfiguration

/// Connection settings for one MCP server.
public struct MCPConfiguration: Sendable {
    public let transport: MCPTransport

    /// Connection timeout in seconds. Currently recorded but not enforced by either transport.
    public let timeout: TimeInterval

    /// Extra environment for a stdio server. Merged over the parent process environment, so
    /// the child inherits everything else. Ignored by the HTTP transport.
    public let environment: [String: String]

    /// Credentials for the HTTP transport. Ignored by stdio.
    public let authorization: MCPAuthorization

    public init(
        transport: MCPTransport,
        timeout: TimeInterval = 30,
        environment: [String: String] = [:],
        authorization: MCPAuthorization = .none
    ) {
        self.transport = transport
        self.timeout = timeout
        self.environment = environment
        self.authorization = authorization
    }
}

// MARK: - MCPTransport

/// How to reach an MCP server.
public enum MCPTransport: Sendable {
    #if os(macOS) || os(Linux)
    /// Launches a subprocess and speaks newline-delimited JSON-RPC over its stdin and stdout.
    ///
    /// Not available on iOS, which cannot spawn a subprocess. The command runs with the parent's
    /// environment plus any overrides, and its
    /// stderr is forwarded to the transport logger rather than the terminal.
    case stdio(command: String, arguments: [String])
    #endif

    /// Talks to a remote server over Streamable HTTP.
    case http(url: URL)
}

// MARK: - MCPToolSelection

/// Which of a server's tools are exposed to the model.
///
/// This is a filter over the tool list, not a sandbox: an excluded tool is merely not offered,
/// and a server that ignores its own advertised capabilities is not constrained by it. The
/// preset modes rely on the `readOnlyHint` and `destructiveHint` annotations the server sends,
/// which are hints — a server that omits them is treated as writable and non-destructive.
public struct MCPToolSelection: Sendable {
    public let mode: Mode

    public enum Mode: Sendable {
        case all

        /// Keeps only the named tools. A name that no tool has is silently ignored.
        case including(Set<String>)

        /// Drops the named tools. A name that no tool has is silently ignored.
        case excluding(Set<String>)

        /// Selects by the server's own capability annotations rather than by name.
        case preset(Preset)
    }

    /// Selection driven by the server's tool annotations.
    public enum Preset: Sendable {
        /// Only tools annotated `readOnlyHint`.
        case readOnly

        /// Everything not annotated `readOnlyHint`, including destructive tools.
        case writeOnly

        /// Everything except tools annotated `destructiveHint`. Read-only tools are included.
        case safe
    }

    public static let all = MCPToolSelection(mode: .all)

    public init(mode: Mode) {
        self.mode = mode
    }

    /// Keeps only the named tools.
    public static func including(_ toolNames: String...) -> MCPToolSelection {
        MCPToolSelection(mode: .including(Set(toolNames)))
    }

    /// Keeps only the named tools.
    public static func including(_ toolNames: Set<String>) -> MCPToolSelection {
        MCPToolSelection(mode: .including(toolNames))
    }

    /// Drops the named tools.
    public static func excluding(_ toolNames: String...) -> MCPToolSelection {
        MCPToolSelection(mode: .excluding(Set(toolNames)))
    }

    /// Drops the named tools.
    public static func excluding(_ toolNames: Set<String>) -> MCPToolSelection {
        MCPToolSelection(mode: .excluding(toolNames))
    }

    /// Only tools the server annotates as read-only.
    public static let readOnly = MCPToolSelection(mode: .preset(.readOnly))

    /// Only tools the server does not annotate as read-only.
    public static let writeOnly = MCPToolSelection(mode: .preset(.writeOnly))

    /// Everything except tools the server annotates as destructive.
    public static let safe = MCPToolSelection(mode: .preset(.safe))

    /// Decides whether one tool survives this selection.
    func includes(toolName: String, capabilities: MCPToolCapabilities) -> Bool {
        switch mode {
        case .all:
            return true
        case .including(let names):
            return names.contains(toolName)
        case .excluding(let names):
            return !names.contains(toolName)
        case .preset(let preset):
            switch preset {
            case .readOnly:
                return capabilities.isReadOnly
            case .writeOnly:
                return !capabilities.isReadOnly
            case .safe:
                return !capabilities.isDangerous
            }
        }
    }
}

// MARK: - MCPToolCapabilities

/// What a tool is allowed to do, as three mutually exclusive states.
///
/// The three states replace an `isReadOnly` / `isDangerous` boolean pair that could express
/// the contradiction "read-only and destructive". These values come from server-supplied
/// hints, so they describe what a tool claims about itself, not what it can actually reach.
public enum MCPToolCapabilities: Sendable, Equatable {
    /// Reads only. Safe to call without confirmation.
    case readOnly

    /// Writes, but reversibly.
    case writeSafe

    /// Writes irreversibly. Deletions, overwrites, anything a user cannot undo.
    case writeDestructive

    public var isReadOnly: Bool { self == .readOnly }

    /// True only for ``writeDestructive``.
    public var isDangerous: Bool { self == .writeDestructive }

    /// Collapses a boolean pair into one state, letting read-only win the contradictory combination.
    ///
    /// - Parameters:
    ///   - isReadOnly: Whether the tool only reads.
    ///   - isDangerous: Whether the tool is destructive. Ignored when `isReadOnly` is true.
    public static func from(isReadOnly: Bool, isDangerous: Bool) -> MCPToolCapabilities {
        if isReadOnly { return .readOnly }
        if isDangerous { return .writeDestructive }
        return .writeSafe
    }
}

// MARK: - MCPServerProtocol Default Extensions

extension MCPServerProtocol {
    /// Connects, lists the server's tools, and keeps the ones ``toolSelection`` allows.
    ///
    /// This is the method to call: ``fetchTools()`` skips the filter.
    public func getFilteredTools() async throws -> [MCPTool] {
        let allTools = try await fetchTools()
        return allTools.filter { tool in
            toolSelection.includes(toolName: tool.toolName, capabilities: tool.capabilities)
        }
    }
}

// MARK: - MCPServer

/// A connection to one MCP server, over a subprocess or over HTTP.
///
/// Every call builds a fresh connection and tears it down afterwards: ``fetchTools()`` and
/// ``executeTool(named:arguments:)`` each start a new subprocess (stdio) or a new client
/// (HTTP), and nothing is pooled between calls. A stdio server therefore pays process
/// startup on every tool call, and a server that keeps state in memory forgets it between
/// calls. Teardown is fire-and-forget, so it may outlive the method that started it.
///
/// ```swift
/// let tools = ToolSet {
///     MCPServer(command: "npx", arguments: ["-y", "@anthropic/mcp-server-filesystem", "/path"])
///         .readOnly
///
///     MCPServer(url: URL(string: "http://localhost:8080")!)
///         .excluding("dangerous_tool")
/// }
/// ```
public struct MCPServer: MCPServerProtocol {
    // MARK: - Properties

    public let serverName: String
    public let configuration: MCPConfiguration
    public var toolSelection: MCPToolSelection

    /// What a new adapter needs, kept separate from `configuration` so it stays Sendable.
    private enum AdapterConfig: @unchecked Sendable {
        #if os(macOS) || os(Linux)
        case stdio(command: String, arguments: [String], environment: [String: String])
        #endif
        case http(url: URL, authorization: MCPAuthorization)
    }

    private let adapterConfig: AdapterConfig

    #if os(macOS) || os(Linux)
    // MARK: - Initialization (stdio)

    /// Configures a server that runs as a subprocess. Not available on iOS.
    ///
    /// Nothing is launched here; the process starts on the first ``fetchTools()`` or
    /// ``executeTool(named:arguments:)`` call, so a bad command surfaces then and not now.
    ///
    /// - Parameters:
    ///   - command: Absolute path to the executable. It is not resolved through `PATH`.
    ///   - arguments: Arguments passed to the executable.
    ///   - name: Identifier for this server. Defaults to the last path component of `command`.
    ///   - environment: Variables added on top of the parent process environment.
    ///   - timeout: Recorded on ``configuration`` but not currently enforced.
    public init(
        command: String,
        arguments: [String] = [],
        name: String? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval = 30
    ) {
        self.serverName = name ?? URL(fileURLWithPath: command).lastPathComponent
        self.configuration = MCPConfiguration(
            transport: .stdio(command: command, arguments: arguments),
            timeout: timeout,
            environment: environment
        )
        self.toolSelection = .all
        self.adapterConfig = .stdio(command: command, arguments: arguments, environment: environment)
    }
    #endif

    // MARK: - Initialization (HTTP)

    /// Configures a remote server reached over Streamable HTTP.
    ///
    /// This is the portable path — unlike stdio it is available on every platform. Nothing
    /// connects here; the first tool listing or call opens the connection.
    ///
    /// ```swift
    /// MCPServer(url: URL(string: "https://example.com/mcp")!)
    ///
    /// MCPServer(
    ///     url: URL(string: "https://mcp.notion.com/mcp")!,
    ///     authorization: .bearer("ntn_xxxxx")
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - url: Endpoint of the MCP server.
    ///   - name: Identifier for this server. Defaults to the URL host, or `"http-mcp"` if it has none.
    ///   - authorization: Credentials sent with every request.
    ///   - timeout: Recorded on ``configuration`` but not currently enforced.
    public init(
        url: URL,
        name: String? = nil,
        authorization: MCPAuthorization = .none,
        timeout: TimeInterval = 30
    ) {
        self.serverName = name ?? url.host ?? "http-mcp"
        self.configuration = MCPConfiguration(
            transport: .http(url: url),
            timeout: timeout,
            authorization: authorization
        )
        self.toolSelection = .all
        self.adapterConfig = .http(url: url, authorization: authorization)
    }

    // MARK: - MCPServerProtocol

    public func fetchTools() async throws -> [MCPTool] {
        let adapter = createAdapter()
        defer { Task { await adapter.disconnect() } }

        return try await adapter.listTools()
    }

    public func executeTool(named toolName: String, arguments: Data) async throws -> ToolResult {
        let adapter = createAdapter()
        defer { Task { await adapter.disconnect() } }

        return try await adapter.callTool(name: toolName, arguments: arguments)
    }

    // MARK: - Private

    private func createAdapter() -> SDKClientAdapter {
        switch adapterConfig {
        #if os(macOS) || os(Linux)
        case .stdio(let command, let arguments, let environment):
            return SDKClientAdapter(command: command, arguments: arguments, environment: environment)
        #endif
        case .http(let url, let authorization):
            return SDKClientAdapter(url: url, authorization: authorization)
        }
    }
}

// MARK: - MCPServer Fluent API

/// Each of these returns a copy with a new selection; they replace rather than combine, so
/// chaining two of them keeps only the last.
extension MCPServer {
    /// A copy that offers every tool.
    public var all: MCPServer {
        var copy = self
        copy.toolSelection = .all
        return copy
    }

    /// A copy that offers only tools the server annotates as read-only.
    public var readOnly: MCPServer {
        var copy = self
        copy.toolSelection = .readOnly
        return copy
    }

    /// A copy that offers everything except tools the server annotates as destructive.
    public var safe: MCPServer {
        var copy = self
        copy.toolSelection = .safe
        return copy
    }

    /// A copy that offers only the named tools.
    public func including(_ toolNames: String...) -> MCPServer {
        var copy = self
        copy.toolSelection = .including(Set(toolNames))
        return copy
    }

    /// A copy that offers only the named tools.
    public func including(_ toolNames: Set<String>) -> MCPServer {
        var copy = self
        copy.toolSelection = .including(toolNames)
        return copy
    }

    /// A copy that hides the named tools.
    public func excluding(_ toolNames: String...) -> MCPServer {
        var copy = self
        copy.toolSelection = .excluding(Set(toolNames))
        return copy
    }

    /// A copy that hides the named tools.
    public func excluding(_ toolNames: Set<String>) -> MCPServer {
        var copy = self
        copy.toolSelection = .excluding(toolNames)
        return copy
    }
}

// MARK: - MCPServer Presets

extension MCPServer {
    /// Notion's hosted MCP server, over Streamable HTTP with bearer authentication.
    ///
    /// The integration sees only the pages and databases it has been connected to, so an
    /// empty tool result usually means the integration was never shared with that page
    /// rather than that the page is missing.
    ///
    /// ```swift
    /// let tools = ToolSet {
    ///     MCPServer.notion(token: "ntn_xxxxx")
    /// }
    /// ```
    ///
    /// Before this works: create an integration at
    /// <https://www.notion.so/profile/integrations>, copy its secret, then connect the
    /// integration to each page or database it should reach.
    ///
    /// - Parameter token: Notion integration secret, which starts with `ntn_`.
    ///
    /// - SeeAlso: [Notion MCP Documentation](https://developers.notion.com/docs/mcp)
    public static func notion(token: String) -> MCPServer {
        MCPServer(
            url: URL(string: "https://mcp.notion.com/mcp")!,
            name: "notion",
            authorization: .bearer(token)
        )
    }
}

