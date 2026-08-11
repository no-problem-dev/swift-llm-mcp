import Foundation
import LLMClient
import LLMTool

// MARK: - ToolKit Protocol

/// A group of related tools implemented in Swift rather than behind an MCP server.
///
/// Use one when you would otherwise run an official MCP server (filesystem, memory, fetch)
/// as a subprocess: the tools run in-process, so there is no process to launch, no JSON-RPC
/// round trip, and no separate sandbox — a ToolKit has whatever access this process has.
///
/// ```swift
/// let tools = ToolSet {
///     MCPServer(command: "npx", arguments: ["-y", "@anthropic/mcp-server-brave"])
///     FileSystemToolKit(allowedPaths: ["/tmp"])
/// }
/// ```
///
/// Conforming takes two properties:
///
/// ```swift
/// public struct MyToolKit: ToolKit {
///     public var name: String { "my-toolkit" }
///
///     public var tools: [any Tool] {
///         [MyTool1(), MyTool2()]
///     }
/// }
/// ```
public protocol ToolKit: Sendable {
    /// Identifies the kit in logs. Never shown to the model, and not required to be unique.
    var name: String { get }

    /// The tools this kit contributes. Every one of them reaches the model.
    ///
    /// Read each time it is used, so a computed implementation must be cheap and must
    /// return a stable list — tools that come and go between reads will confuse the model.
    var tools: [any Tool] { get }
}

// MARK: - ToolKit Default Extensions

extension ToolKit {
    public var toolCount: Int {
        tools.count
    }

    public var toolNames: [String] {
        tools.map { $0.toolName }
    }

    /// Finds a tool by name, returning the first match if the kit has duplicates.
    ///
    /// - Parameter name: Exact tool name; the comparison is case-sensitive.
    public func tool(named name: String) -> (any Tool)? {
        tools.first { $0.toolName == name }
    }
}

// MARK: - BuiltInTool

/// A tool implemented as a closure, for use inside a ``ToolKit``.
///
/// It carries MCP tool annotations so an in-process tool can be filtered by the same
/// ``MCPToolSelection`` presets as a remote one.
public struct BuiltInTool: Tool, Sendable {
    // MARK: - Properties

    public let toolName: String
    public let toolDescription: String
    public let inputSchema: JSONSchema
    public let annotations: ToolAnnotations

    private let executeHandler: @Sendable (Data) async throws -> ToolResult

    // MARK: - Initialization

    /// Creates a tool.
    ///
    /// - Parameters:
    ///   - name: Tool name the model calls.
    ///   - description: What the model reads when deciding whether to call it.
    ///   - inputSchema: Argument schema. The handler still has to validate; nothing here enforces it.
    ///   - annotations: Capability hints. Leaving them empty classifies the tool as
    ///     destructive — see ``capabilities``.
    ///   - handler: Performs the call, receiving raw JSON argument data.
    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        annotations: ToolAnnotations = ToolAnnotations(),
        handler: @escaping @Sendable (Data) async throws -> ToolResult
    ) {
        self.toolName = name
        self.toolDescription = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.executeHandler = handler
    }

    // MARK: - Tool Protocol

    public func execute(with argumentsData: Data) async throws -> ToolResult {
        try await executeHandler(argumentsData)
    }

    // MARK: - Capabilities Conversion

    /// This tool's classification, derived from its annotations.
    ///
    /// Unannotated defaults to ``MCPToolCapabilities/writeDestructive``, so a tool that
    /// declares nothing is excluded by the `.safe` and `.readOnly` presets. That is the
    /// opposite of ``MCPTool``, whose unannotated default is `writeSafe` — an in-process
    /// tool is assumed dangerous until it says otherwise.
    public var capabilities: MCPToolCapabilities {
        let isReadOnly = annotations.readOnlyHint ?? false
        let isDangerous = isReadOnly ? false : (annotations.destructiveHint ?? true)
        return MCPToolCapabilities.from(isReadOnly: isReadOnly, isDangerous: isDangerous)
    }
}
