import Testing
@testable import LLMMCP
import LLMClient
import LLMTool

@Test func testMCPImport() {
    #expect(Bool(true))
}

@Test func testMCPToolSelection() {
    let selection = MCPToolSelection.all
    let capabilities = MCPToolCapabilities.writeSafe
    #expect(selection.includes(toolName: "test", capabilities: capabilities) == true)
}
