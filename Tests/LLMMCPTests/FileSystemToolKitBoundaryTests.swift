import Testing
import Foundation
import LLMTool
@testable import LLMMCP

// MARK: - FileSystemToolKit Path Containment Tests

/// The boundary seen from where a model stands: every case goes through a tool call, and the
/// refusals are asserted, not just the permitted cases.
@Suite("FileSystemToolKit Path Boundary")
struct FileSystemToolKitBoundaryTests {

    // MARK: - Helpers

    /// A throwaway directory to build layouts in. Not itself the allowed root — the tests
    /// place the root inside it so they can also create siblings and outsiders.
    private func makeBaseDirectory() -> String {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-boundary-test-\(UUID().uuidString)")
            .path
        try! FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }

    private func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func jsonData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    private func makeDirectory(_ path: String) {
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func writeFile(_ path: String, _ contents: String) {
        try! contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Runs `body` and requires it to fail with ``FileSystemToolKitError/accessDenied(path:allowedPaths:)``.
    ///
    /// The case matters: `fileNotFound` is the same error type and would let a broken
    /// boundary pass a looser assertion.
    private func expectAccessDenied(
        _ description: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("Expected accessDenied for \(description), but the call succeeded", sourceLocation: sourceLocation)
        } catch let error as FileSystemToolKitError {
            guard case .accessDenied = error else {
                Issue.record("Expected accessDenied for \(description), got \(error)", sourceLocation: sourceLocation)
                return
            }
        } catch {
            Issue.record("Expected accessDenied for \(description), got \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Sibling Directory Sharing a Name Prefix

    @Test("A sibling directory whose name extends the allowed root is not inside it")
    func siblingWithSharedNamePrefixIsRefusedOnRead() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("data")
        let sibling = (base as NSString).appendingPathComponent("database")
        makeDirectory(allowedRoot)
        makeDirectory(sibling)

        let secret = (sibling as NSString).appendingPathComponent("secret.txt")
        writeFile(secret, "top secret")

        let toolkit = FileSystemToolKit(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)

        await expectAccessDenied("read_file on \(secret)") {
            _ = try await toolkit.tool(named: "read_file")!.execute(with: self.jsonData(["path": secret]))
        }
    }

    @Test("A sibling directory whose name extends the allowed root cannot be written into")
    func siblingWithSharedNamePrefixIsRefusedOnWrite() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("data")
        let sibling = (base as NSString).appendingPathComponent("database")
        makeDirectory(allowedRoot)
        makeDirectory(sibling)

        let target = (sibling as NSString).appendingPathComponent("planted.txt")
        let toolkit = FileSystemToolKit(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)

        await expectAccessDenied("write_file to \(target)") {
            _ = try await toolkit.tool(named: "write_file")!.execute(
                with: self.jsonData(["path": target, "content": "planted"])
            )
        }

        #expect(FileManager.default.fileExists(atPath: target) == false)
    }

    // MARK: - Symlink Escape

    @Test("Reading through a symlink that points out of the allowed root is refused")
    func symlinkOutOfRootIsRefusedOnRead() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("allowed")
        let outside = (base as NSString).appendingPathComponent("outside")
        makeDirectory(allowedRoot)
        makeDirectory(outside)

        let secret = (outside as NSString).appendingPathComponent("secret.txt")
        writeFile(secret, "top secret")

        // A link the model could have been handed, or could have created itself.
        let link = (allowedRoot as NSString).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)

        let toolkit = FileSystemToolKit(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)
        let throughLink = (link as NSString).appendingPathComponent("secret.txt")

        await expectAccessDenied("read_file through \(throughLink)") {
            _ = try await toolkit.tool(named: "read_file")!.execute(with: self.jsonData(["path": throughLink]))
        }
    }

    @Test("Writing through a symlink that points out of the allowed root is refused")
    func symlinkOutOfRootIsRefusedOnWrite() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("allowed")
        let outside = (base as NSString).appendingPathComponent("outside")
        makeDirectory(allowedRoot)
        makeDirectory(outside)

        let link = (allowedRoot as NSString).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)

        let toolkit = FileSystemToolKit(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)
        let throughLink = (link as NSString).appendingPathComponent("planted.txt")

        await expectAccessDenied("write_file through \(throughLink)") {
            _ = try await toolkit.tool(named: "write_file")!.execute(
                with: self.jsonData(["path": throughLink, "content": "planted"])
            )
        }

        let landedOutside = (outside as NSString).appendingPathComponent("planted.txt")
        #expect(FileManager.default.fileExists(atPath: landedOutside) == false)
    }

    @Test("A symlink to a single file outside the allowed root is refused")
    func symlinkToFileOutOfRootIsRefused() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("allowed")
        let outside = (base as NSString).appendingPathComponent("outside")
        makeDirectory(allowedRoot)
        makeDirectory(outside)

        let secret = (outside as NSString).appendingPathComponent("secret.txt")
        writeFile(secret, "top secret")

        let link = (allowedRoot as NSString).appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: secret)

        let toolkit = FileSystemToolKit(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)

        await expectAccessDenied("read_file on \(link)") {
            _ = try await toolkit.tool(named: "read_file")!.execute(with: self.jsonData(["path": link]))
        }
    }

    // MARK: - Climbing Out With ..

    @Test("A relative path climbing above the allowed root is refused")
    func parentTraversalIsRefused() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("allowed")
        makeDirectory(allowedRoot)

        let secret = (base as NSString).appendingPathComponent("secret.txt")
        writeFile(secret, "top secret")

        let toolkit = FileSystemToolKit(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)

        await expectAccessDenied("read_file on ../secret.txt") {
            _ = try await toolkit.tool(named: "read_file")!.execute(with: self.jsonData(["path": "../secret.txt"]))
        }
    }

    // MARK: - Ordinary In-Root Work Still Works

    @Test("Creating, reading and listing inside the allowed root still works")
    func inRootWorkIsPermitted() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("allowed")
        makeDirectory(allowedRoot)

        let toolkit = FileSystemToolKit(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)

        // A file that does not exist yet: the check has to allow a path it cannot canonicalize whole.
        let newFile = (allowedRoot as NSString).appendingPathComponent("notes/today.md")
        let written = try await toolkit.tool(named: "write_file")!.execute(
            with: jsonData(["path": newFile, "content": "hello"])
        )
        #expect(written.stringValue.contains("Successfully wrote"))

        let read = try await toolkit.tool(named: "read_file")!.execute(with: jsonData(["path": newFile]))
        #expect(read.stringValue == "hello")

        // Relative paths, and the working directory itself.
        let relative = try await toolkit.tool(named: "read_file")!.execute(with: jsonData(["path": "notes/today.md"]))
        #expect(relative.stringValue == "hello")

        let listed = try await toolkit.tool(named: "list_directory")!.execute(with: jsonData(["path": "."]))
        #expect(listed.stringValue.contains("notes"))

        // A directory created through the tool, and the root itself.
        let made = try await toolkit.tool(named: "create_directory")!.execute(
            with: jsonData(["path": (allowedRoot as NSString).appendingPathComponent("fresh/deeper")])
        )
        #expect(made.stringValue.contains("Successfully created"))

        let info = try await toolkit.tool(named: "get_file_info")!.execute(with: jsonData(["path": allowedRoot]))
        #expect(info.stringValue.contains("directory"))
    }

    @Test("A symlink that stays inside the allowed root is still usable")
    func symlinkInsideRootIsPermitted() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let allowedRoot = (base as NSString).appendingPathComponent("allowed")
        let inner = (allowedRoot as NSString).appendingPathComponent("inner")
        makeDirectory(inner)

        let real = (inner as NSString).appendingPathComponent("real.txt")
        writeFile(real, "in root")

        let link = (allowedRoot as NSString).appendingPathComponent("shortcut")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: inner)

        let toolkit = FileSystemToolKit(allowedPaths: [allowedRoot], workingDirectory: allowedRoot)
        let throughLink = (link as NSString).appendingPathComponent("real.txt")

        let read = try await toolkit.tool(named: "read_file")!.execute(with: jsonData(["path": throughLink]))
        #expect(read.stringValue == "in root")
    }

    @Test("The allowed root may itself be reached through a symlinked path")
    func allowedRootGivenThroughSymlinkIsUsable() async throws {
        let base = makeBaseDirectory()
        defer { remove(base) }

        let realRoot = (base as NSString).appendingPathComponent("real-root")
        makeDirectory(realRoot)

        // The caller names the root by a symlink to it, which is what /tmp and the temporary
        // directory are on macOS.
        let linkedRoot = (base as NSString).appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(atPath: linkedRoot, withDestinationPath: realRoot)

        let toolkit = FileSystemToolKit(allowedPaths: [linkedRoot], workingDirectory: linkedRoot)

        let target = (realRoot as NSString).appendingPathComponent("file.txt")
        let written = try await toolkit.tool(named: "write_file")!.execute(
            with: jsonData(["path": target, "content": "hello"])
        )
        #expect(written.stringValue.contains("Successfully wrote"))
    }
}
