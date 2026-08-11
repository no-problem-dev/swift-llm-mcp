#if canImport(JavaScriptCore)
import Testing
import Foundation
import LLMTool
@testable import LLMMCP

// MARK: - ScriptBridge Path Containment Tests

/// The same boundary as ``FileSystemToolKitBoundaryTests``, seen through the `ios` file APIs
/// a script calls. Failures there are strings, not thrown errors, so the assertions read the
/// returned text — including that the secret is not in it.
@Suite("ScriptBridge Path Boundary")
struct ScriptToolKitBoundaryTests {

    // MARK: - Helpers

    private func makeBaseDirectory() -> String {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-boundary-test-\(UUID().uuidString)")
            .path
        try! FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }

    private func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func makeDirectory(_ path: String) {
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func writeFile(_ path: String, _ contents: String) {
        try! contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Runs one script through `run_script` and returns what the model would see.
    private func run(_ code: String, on toolkit: ScriptToolKit) async throws -> String {
        let arguments = try JSONSerialization.data(withJSONObject: ["code": code])
        return try await toolkit.tool(named: "run_script")!.execute(with: arguments).stringValue
    }

    /// A JavaScript string literal for a path, so a path never breaks the script.
    private func literal(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Sibling Directory Sharing a Name Prefix

    @Test("ios.readFile refuses a sibling directory whose name extends the allowed root")
    func siblingWithSharedNamePrefixIsRefused() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("data")
        let sibling = (base as NSString).appendingPathComponent("database")
        makeDirectory(allowedRoot)
        makeDirectory(sibling)

        let secret = (sibling as NSString).appendingPathComponent("secret.txt")
        writeFile(secret, "top secret")

        let toolkit = ScriptToolKit(
            bridge: ScriptBridge(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)
        )

        let output = try await run("ios.readFile(\(literal(secret)))", on: toolkit)
        #expect(output.contains("top secret") == false)
        #expect(output.contains("Access denied"))
    }

    @Test("ios.writeFile refuses a sibling directory whose name extends the allowed root")
    func siblingWithSharedNamePrefixIsRefusedOnWrite() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("data")
        let sibling = (base as NSString).appendingPathComponent("database")
        makeDirectory(allowedRoot)
        makeDirectory(sibling)

        let target = (sibling as NSString).appendingPathComponent("planted.txt")
        let toolkit = ScriptToolKit(
            bridge: ScriptBridge(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)
        )

        let output = try await run("ios.writeFile(\(literal(target)), \"planted\")", on: toolkit)
        #expect(output.contains("true") == false)
        #expect(FileManager.default.fileExists(atPath: target) == false)
    }

    // MARK: - Symlink Escape

    @Test("ios.readFile refuses a path leading out through a symlink")
    func symlinkOutOfRootIsRefusedOnRead() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("allowed")
        let outside = (base as NSString).appendingPathComponent("outside")
        makeDirectory(allowedRoot)
        makeDirectory(outside)

        let secret = (outside as NSString).appendingPathComponent("secret.txt")
        writeFile(secret, "top secret")

        let link = (allowedRoot as NSString).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)

        let toolkit = ScriptToolKit(
            bridge: ScriptBridge(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)
        )

        let throughLink = (link as NSString).appendingPathComponent("secret.txt")
        let output = try await run("ios.readFile(\(literal(throughLink)))", on: toolkit)
        #expect(output.contains("top secret") == false)
        #expect(output.contains("Access denied"))
    }

    @Test("ios.writeFile refuses a path leading out through a symlink")
    func symlinkOutOfRootIsRefusedOnWrite() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("allowed")
        let outside = (base as NSString).appendingPathComponent("outside")
        makeDirectory(allowedRoot)
        makeDirectory(outside)

        let link = (allowedRoot as NSString).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)

        let toolkit = ScriptToolKit(
            bridge: ScriptBridge(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)
        )

        let throughLink = (link as NSString).appendingPathComponent("planted.txt")
        let output = try await run("ios.writeFile(\(literal(throughLink)), \"planted\")", on: toolkit)
        #expect(output.contains("true") == false)

        let landedOutside = (outside as NSString).appendingPathComponent("planted.txt")
        #expect(FileManager.default.fileExists(atPath: landedOutside) == false)
    }

    @Test("ios.listFiles refuses a directory reached through a symlink out of the root")
    func symlinkOutOfRootIsRefusedOnList() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("allowed")
        let outside = (base as NSString).appendingPathComponent("outside")
        makeDirectory(allowedRoot)
        makeDirectory(outside)
        writeFile((outside as NSString).appendingPathComponent("secret.txt"), "top secret")

        let link = (allowedRoot as NSString).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)

        let toolkit = ScriptToolKit(
            bridge: ScriptBridge(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)
        )

        let output = try await run("ios.listFiles(\(literal(link))).join(\",\")", on: toolkit)
        #expect(output.contains("secret.txt") == false)
        #expect(output.contains("Access denied"))
    }

    // MARK: - Ordinary In-Root Work Still Works

    @Test("Reading and writing inside the allowed root still works")
    func inRootWorkIsPermitted() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("allowed")
        makeDirectory(allowedRoot)
        writeFile((allowedRoot as NSString).appendingPathComponent("existing.txt"), "in root")

        let toolkit = ScriptToolKit(
            bridge: ScriptBridge(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)
        )

        let read = try await run("ios.readFile(\"existing.txt\")", on: toolkit)
        #expect(read.contains("in root"))

        // A file that does not exist yet, in a directory that does not exist yet.
        let created = try await run("ios.writeFile(\"notes/today.md\", \"hello\")", on: toolkit)
        #expect(created.contains("true"))

        let listed = try await run("ios.listFiles(\".\").join(\",\")", on: toolkit)
        #expect(listed.contains("existing.txt"))
        #expect(listed.contains("notes"))
    }
}
#endif
