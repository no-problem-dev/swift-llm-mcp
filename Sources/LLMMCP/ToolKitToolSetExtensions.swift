import Foundation
import LLMTool

// MARK: - ToolSetBuilder Extension for ToolKit

extension ToolSetBuilder {
    /// Accepts a ``ToolKit`` in a `ToolSet` builder, flattening it into its tools.
    ///
    /// Unlike an MCP server this needs no resolution step — the tools are available
    /// immediately, so a kit and a plain tool can be mixed freely.
    ///
    /// ```swift
    /// let tools = ToolSet {
    ///     WebToolKit()
    ///     GetWeatherTool()
    /// }
    /// ```
    public static func buildExpression(_ toolkit: some ToolKit) -> [any Tool] {
        toolkit.tools
    }
}

// MARK: - ToolSet Extension for ToolKit

extension ToolSet {
    /// A copy of this set with a kit's tools appended. Duplicate tool names are not detected.
    public func appending(_ toolkit: some ToolKit) -> ToolSet {
        ToolSet(tools: self.tools + toolkit.tools)
    }

    /// Operator form of ``appending(_:)``.
    public static func + (lhs: ToolSet, rhs: some ToolKit) -> ToolSet {
        ToolSet(tools: lhs.tools + rhs.tools)
    }

    /// Always returns 0.
    ///
    /// A `ToolSet` stores tools flattened and keeps no record of which kit contributed
    /// each one, so the name cannot be matched against anything.
    public func toolCount(for toolkitName: String) -> Int {
        0
    }
}

// MARK: - Array Extension for ToolKit

extension Array where Element == any Tool {
    /// Builds a plain array from a kit's tools, discarding the kit itself.
    public init(_ toolkit: some ToolKit) {
        self = toolkit.tools
    }
}
