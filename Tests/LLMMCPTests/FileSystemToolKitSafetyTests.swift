import Testing
import Foundation
import LLMTool
@testable import LLMMCP

// MARK: - FileSystemToolKit Read-Before-Write Safety Tests

@Suite("FileSystemToolKit Safety")
struct FileSystemToolKitSafetyTests {

    /// テスト用の一時ディレクトリとツールキットを作成
    private func makeSUT() -> (toolkit: FileSystemToolKit, tempDir: String, cleanup: @Sendable () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-safety-test-\(UUID().uuidString)")
            .path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let toolkit = FileSystemToolKit(allowedPaths: [tempDir], workingDirectory: tempDir)
        let cleanup: @Sendable () -> Void = {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        return (toolkit, tempDir, cleanup)
    }

    /// JSON データを作成するヘルパー
    private func jsonData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - write_file Tests

    @Test func writeNewFileWithoutRead() async throws {
        let (toolkit, tempDir, cleanup) = makeSUT()
        defer { cleanup() }

        let path = (tempDir as NSString).appendingPathComponent("new.txt")
        let result = try await toolkit.tool(named: "write_file")!.execute(
            with: jsonData(["path": path, "content": "hello"])
        )

        #expect(result.stringValue.contains("Successfully wrote"))
        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written == "hello")
    }

    @Test func writeExistingFileWithoutRead() async throws {
        let (toolkit, tempDir, cleanup) = makeSUT()
        defer { cleanup() }

        // 既存ファイルを直接作成
        let path = (tempDir as NSString).appendingPathComponent("existing.txt")
        try "original".write(toFile: path, atomically: true, encoding: .utf8)

        // read なしで write → エラー
        await #expect(throws: FileSystemToolKitError.self) {
            try await toolkit.tool(named: "write_file")!.execute(
                with: jsonData(["path": path, "content": "overwritten"])
            )
        }

        // ファイルが変更されていないことを確認
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "original")
    }

    @Test func writeExistingFileAfterRead() async throws {
        let (toolkit, tempDir, cleanup) = makeSUT()
        defer { cleanup() }

        let path = (tempDir as NSString).appendingPathComponent("existing.txt")
        try "original".write(toFile: path, atomically: true, encoding: .utf8)

        // まず read
        _ = try await toolkit.tool(named: "read_file")!.execute(
            with: jsonData(["path": path])
        )

        // read 後の write は成功
        let result = try await toolkit.tool(named: "write_file")!.execute(
            with: jsonData(["path": path, "content": "updated"])
        )

        #expect(result.stringValue.contains("Successfully wrote"))
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "updated")
    }

    // MARK: - edit_file Tests

    @Test func editFileWithoutRead() async throws {
        let (toolkit, tempDir, cleanup) = makeSUT()
        defer { cleanup() }

        let path = (tempDir as NSString).appendingPathComponent("edit-target.txt")
        try "hello world".write(toFile: path, atomically: true, encoding: .utf8)

        // read なしで edit → エラー
        await #expect(throws: FileSystemToolKitError.self) {
            try await toolkit.tool(named: "edit_file")!.execute(
                with: jsonData(["path": path, "old_string": "hello", "new_string": "hi"])
            )
        }

        // ファイルが変更されていないことを確認
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "hello world")
    }

    @Test func editFileAfterRead() async throws {
        let (toolkit, tempDir, cleanup) = makeSUT()
        defer { cleanup() }

        let path = (tempDir as NSString).appendingPathComponent("edit-target.txt")
        try "hello world".write(toFile: path, atomically: true, encoding: .utf8)

        // まず read
        _ = try await toolkit.tool(named: "read_file")!.execute(
            with: jsonData(["path": path])
        )

        // read 後の edit は成功
        let result = try await toolkit.tool(named: "edit_file")!.execute(
            with: jsonData(["path": path, "old_string": "hello", "new_string": "hi"])
        )

        #expect(result.stringValue.contains("Edited"))
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "hi world")
    }

    // MARK: - read_multiple_files Tests

    @Test func readMultipleFilesTracksAll() async throws {
        let (toolkit, tempDir, cleanup) = makeSUT()
        defer { cleanup() }

        let path1 = (tempDir as NSString).appendingPathComponent("file1.txt")
        let path2 = (tempDir as NSString).appendingPathComponent("file2.txt")
        try "content1".write(toFile: path1, atomically: true, encoding: .utf8)
        try "content2".write(toFile: path2, atomically: true, encoding: .utf8)

        // read_multiple_files で両方読む
        _ = try await toolkit.tool(named: "read_multiple_files")!.execute(
            with: jsonData(["paths": [path1, path2]])
        )

        // 両方のファイルに write できる
        let result1 = try await toolkit.tool(named: "write_file")!.execute(
            with: jsonData(["path": path1, "content": "updated1"])
        )
        let result2 = try await toolkit.tool(named: "write_file")!.execute(
            with: jsonData(["path": path2, "content": "updated2"])
        )

        #expect(result1.stringValue.contains("Successfully wrote"))
        #expect(result2.stringValue.contains("Successfully wrote"))
    }

    // MARK: - Session Persistence Tests

    @Test func writeAfterWriteWithoutReRead() async throws {
        let (toolkit, tempDir, cleanup) = makeSUT()
        defer { cleanup() }

        let path = (tempDir as NSString).appendingPathComponent("persist.txt")
        try "original".write(toFile: path, atomically: true, encoding: .utf8)

        // read → write → 再 write（re-read 不要）
        _ = try await toolkit.tool(named: "read_file")!.execute(
            with: jsonData(["path": path])
        )
        _ = try await toolkit.tool(named: "write_file")!.execute(
            with: jsonData(["path": path, "content": "first write"])
        )
        let result = try await toolkit.tool(named: "write_file")!.execute(
            with: jsonData(["path": path, "content": "second write"])
        )

        #expect(result.stringValue.contains("Successfully wrote"))
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content == "second write")
    }

    // MARK: - Error Message Tests

    @Test func errorMessageContainsGuidance() async throws {
        let (toolkit, tempDir, cleanup) = makeSUT()
        defer { cleanup() }

        let path = (tempDir as NSString).appendingPathComponent("guidance.txt")
        try "test".write(toFile: path, atomically: true, encoding: .utf8)

        do {
            _ = try await toolkit.tool(named: "write_file")!.execute(
                with: jsonData(["path": path, "content": "overwrite"])
            )
            Issue.record("Expected readRequired error")
        } catch let error as FileSystemToolKitError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("read_file"))
            #expect(message.contains(path))
            #expect(message.contains("write_file"))
        }
    }
}
