import Testing
import Foundation
import LLMTool
@testable import LLMMCP

// MARK: - FileSystemToolKit Read Size Limit Tests

/// How much of a file the model can pull into its context in one call.
@Suite("FileSystemToolKit Read Limit")
struct FileSystemToolKitReadLimitTests {

    // MARK: - Helpers

    private func makeSUT(maximumReadBytes: Int) -> (toolkit: FileSystemToolKit, directory: String, cleanup: @Sendable () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-read-limit-test-\(UUID().uuidString)")
            .path
        try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let toolkit = FileSystemToolKit(
            allowedPaths: [directory],
            workingDirectory: directory,
            maximumReadBytes: maximumReadBytes
        )
        return (toolkit, directory, { try? FileManager.default.removeItem(atPath: directory) })
    }

    private func jsonData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    /// Writes a file of exactly `bytes` length whose content is recognisable if it leaks.
    @discardableResult
    private func writeFile(_ path: String, bytes: Int) -> String {
        let contents = String(repeating: "L", count: bytes)
        try! contents.write(toFile: path, atomically: true, encoding: .utf8)
        return contents
    }

    // MARK: - Tests

    @Test("A file over the cap is refused, and the error names the size and the cap")
    func fileOverTheCapIsRefused() async throws {
        let (toolkit, directory, cleanup) = makeSUT(maximumReadBytes: 1024)
        defer { cleanup() }

        let path = (directory as NSString).appendingPathComponent("huge.log")
        writeFile(path, bytes: 4096)

        do {
            let result = try await toolkit.tool(named: "read_file")!.execute(with: jsonData(["path": path]))
            Issue.record("Expected the read to be refused; got \(result.stringValue.count) characters")
        } catch let error as FileSystemToolKitError {
            guard case .fileTooLarge = error else {
                Issue.record("Expected fileTooLarge, got \(error)")
                return
            }
            let message = error.errorDescription ?? ""
            // Both numbers, or the model cannot tell how far over it is.
            #expect(message.contains("4096"))
            #expect(message.contains("1024"))
            #expect(message.contains(path))
        }
    }

    @Test("A file under the cap is read whole")
    func fileUnderTheCapIsRead() async throws {
        let (toolkit, directory, cleanup) = makeSUT(maximumReadBytes: 1024)
        defer { cleanup() }

        let path = (directory as NSString).appendingPathComponent("small.txt")
        let contents = writeFile(path, bytes: 1000)

        let result = try await toolkit.tool(named: "read_file")!.execute(with: jsonData(["path": path]))
        #expect(result.stringValue == contents)
    }

    @Test("A refused read does not make the file writable")
    func refusedReadDoesNotGrantWrite() async throws {
        let (toolkit, directory, cleanup) = makeSUT(maximumReadBytes: 1024)
        defer { cleanup() }

        let path = (directory as NSString).appendingPathComponent("huge.log")
        writeFile(path, bytes: 4096)

        _ = try? await toolkit.tool(named: "read_file")!.execute(with: jsonData(["path": path]))

        // The read never happened, so the overwrite guard must still be armed.
        await #expect(throws: FileSystemToolKitError.self) {
            try await toolkit.tool(named: "write_file")!.execute(
                with: self.jsonData(["path": path, "content": "clobbered"])
            )
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8).count == 4096)
    }

    @Test("read_multiple_files refuses the oversize file and still returns the others")
    func readMultipleFilesRefusesOnlyTheOversizeOne() async throws {
        let (toolkit, directory, cleanup) = makeSUT(maximumReadBytes: 1024)
        defer { cleanup() }

        let small = (directory as NSString).appendingPathComponent("small.txt")
        let huge = (directory as NSString).appendingPathComponent("huge.log")
        writeFile(small, bytes: 10)
        writeFile(huge, bytes: 4096)

        let result = try await toolkit.tool(named: "read_multiple_files")!.execute(
            with: jsonData(["paths": [small, huge]])
        )
        let output = result.stringValue

        #expect(output.contains(String(repeating: "L", count: 10)))
        #expect(output.contains(String(repeating: "L", count: 4096)) == false)
        #expect(output.contains("4096"))
        #expect(output.contains("1024"))
    }
}
