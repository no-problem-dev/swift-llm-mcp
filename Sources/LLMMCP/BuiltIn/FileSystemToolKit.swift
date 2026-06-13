import Foundation
import LLMClient
import LLMTool
import os

// MARK: - FileSystemToolKit

/// ファイルシステム操作ツールを提供するToolKit
///
/// 公式MCP Filesystem Serverに準拠した実装です。
/// `allowedPaths` を指定すると、許可されたパス以下のみにアクセスを制限します。
/// 省略した場合は iOS サンドボックスの制約のみが適用されます。
///
/// ## 使用例
///
/// ```swift
/// // iOS: サンドボックス内は全てアクセス可能（Documents が working directory）
/// let tools = ToolSet {
///     FileSystemToolKit()
/// }
///
/// // macOS: 特定ディレクトリのみ許可
/// let tools = ToolSet {
///     FileSystemToolKit(
///         allowedPaths: ["/Users/user/projects"],
///         workingDirectory: "/Users/user/projects"
///     )
/// }
/// ```
///
/// ## 提供されるツール
///
/// - `read_file`: ファイルの内容を読み取り
/// - `read_multiple_files`: 複数ファイルを一度に読み取り
/// - `write_file`: ファイルを作成または上書き
/// - `edit_file`: 文字列置換によるファイル編集
/// - `create_directory`: ディレクトリを作成
/// - `list_directory`: ディレクトリの内容一覧
/// - `directory_tree`: ディレクトリツリー表示
/// - `move_file`: ファイル/ディレクトリの移動・名前変更
/// - `search_files`: ファイル検索（パターンマッチング）
/// - `grep_files`: ファイル内容の正規表現検索
/// - `get_file_info`: ファイル情報取得
public final class FileSystemToolKit: ToolKit, @unchecked Sendable {
    // MARK: - Properties

    public let name: String = "filesystem"

    /// 許可されたパス（nil の場合は全パス許可）
    private let allowedPaths: [String]?

    /// 相対パスの基準となる作業ディレクトリ
    ///
    /// 相対パス（`/` で始まらないパス）はこのディレクトリを基準に解決されます。
    /// デフォルトではアプリの Documents ディレクトリが使用されます。
    private let workingDirectory: String

    /// FileManager
    private let fileManager: FileManager

    /// 読み取り済みファイルパスを追跡（write/edit 前の read 強制用）
    private let readPaths = OSAllocatedUnfairLock(initialState: Set<String>())

    // MARK: - Initialization

    /// FileSystemToolKitを作成
    ///
    /// - Parameters:
    ///   - allowedPaths: アクセスを許可するパスの配列（nil で全パス許可）
    ///     チルダ（~）はホームディレクトリに展開されます。
    ///     iOS ではサンドボックスが OS レベルで制限するため、nil（全許可）で問題ありません。
    ///   - workingDirectory: 相対パスの基準ディレクトリ（nil でアプリの Documents ディレクトリ）
    public init(allowedPaths: [String]? = nil, workingDirectory: String? = nil) {
        self.allowedPaths = allowedPaths?.map { path in
            NSString(string: path).expandingTildeInPath
        }
        self.workingDirectory = workingDirectory ?? Self.defaultWorkingDirectory
        self.fileManager = FileManager.default
    }

    /// ワークスペースから初期化
    ///
    /// ワークスペースの `rootDirectory` を `allowedPaths` に、
    /// `workingDirectory` をツールの作業ディレクトリに設定します。
    ///
    /// - Parameter workspace: ワークスペース
    public convenience init(workspace: Workspace) {
        self.init(
            allowedPaths: [workspace.rootDirectory] + workspace.additionalAllowedPaths,
            workingDirectory: workspace.workingDirectory
        )
    }

    /// デフォルトの作業ディレクトリ（Documents）
    private static var defaultWorkingDirectory: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.currentDirectoryPath
    }

    // MARK: - ToolKit Protocol

    public var tools: [any Tool] {
        [
            readFileTool,
            readMultipleFilesTool,
            writeFileTool,
            editFileTool,
            createDirectoryTool,
            listDirectoryTool,
            directoryTreeTool,
            moveFileTool,
            searchFilesTool,
            grepFilesTool,
            getFileInfoTool
        ]
    }

    // MARK: - Path Validation

    /// パスを解決し、許可されているかチェック
    ///
    /// 相対パス（`/` で始まらないパス）は `workingDirectory` を基準に解決される。
    /// `"."` は `workingDirectory` そのものを返す。
    private func validatePath(_ path: String) throws -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath

        // 相対パスなら workingDirectory を基準に解決
        let absolutePath: String
        if expandedPath.hasPrefix("/") {
            absolutePath = expandedPath
        } else {
            absolutePath = (workingDirectory as NSString).appendingPathComponent(expandedPath)
        }

        let resolvedPath = URL(fileURLWithPath: absolutePath).standardizedFileURL.path

        // allowedPaths が nil なら全パス許可
        guard let allowedPaths else { return resolvedPath }

        // 許可されたパス内にあるかチェック
        let isAllowed = allowedPaths.contains { allowedPath in
            resolvedPath.hasPrefix(allowedPath)
        }

        guard isAllowed else {
            throw FileSystemToolKitError.accessDenied(path: resolvedPath, allowedPaths: allowedPaths)
        }

        return resolvedPath
    }

    // MARK: - Read Tracking

    private func recordRead(_ path: String) {
        readPaths.withLock { $0.insert(path) }
    }

    private func hasRead(_ path: String) -> Bool {
        readPaths.withLock { $0.contains(path) }
    }

    // MARK: - Tool Definitions

    /// read_file ツール
    private var readFileTool: BuiltInTool {
        BuiltInTool(
            name: "read_file",
            description: "Read the complete contents of a file. Working directory: \(workingDirectory). Relative paths are resolved against this directory. Use absolute paths to access other locations.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Absolute or relative path to the file to read")
                ],
                required: ["path"]
            ),
            annotations: ToolAnnotations(
                title: "Read File",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(ReadFileInput.self, from: data)
            let validPath = try validatePath(input.path)

            guard let content = fileManager.contents(atPath: validPath) else {
                throw FileSystemToolKitError.fileNotFound(path: validPath)
            }

            guard let text = String(data: content, encoding: .utf8) else {
                throw FileSystemToolKitError.encodingError(path: validPath)
            }

            self.recordRead(validPath)
            return .text(text)
        }
    }

    /// read_multiple_files ツール
    private var readMultipleFilesTool: BuiltInTool {
        BuiltInTool(
            name: "read_multiple_files",
            description: "Read the contents of multiple files simultaneously. Returns content with path labels.",
            inputSchema: .object(
                properties: [
                    "paths": .array(
                        description: "Array of file paths to read",
                        items: .string()
                    )
                ],
                required: ["paths"]
            ),
            annotations: ToolAnnotations(
                title: "Read Multiple Files",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(ReadMultipleFilesInput.self, from: data)
            var results: [FileReadResult] = []

            for path in input.paths {
                do {
                    let validPath = try validatePath(path)
                    guard let content = fileManager.contents(atPath: validPath),
                          let text = String(data: content, encoding: .utf8) else {
                        results.append(FileReadResult(path: path, content: nil, error: "Could not read file"))
                        continue
                    }
                    self.recordRead(validPath)
                    results.append(FileReadResult(path: path, content: text, error: nil))
                } catch {
                    results.append(FileReadResult(path: path, content: nil, error: error.localizedDescription))
                }
            }

            let output = try JSONEncoder().encode(results)
            return .json(output)
        }
    }

    /// write_file ツール
    private var writeFileTool: BuiltInTool {
        BuiltInTool(
            name: "write_file",
            description: "Create a new file or overwrite an existing file with new contents. Use this tool when the user asks to: save content to a file, create a document, export as Markdown or text, write a summary to a file, or any request that implies creating a persistent file on the filesystem. Creates parent directories if needed. IMPORTANT: You must use read_file before overwriting an existing file — this tool will fail otherwise. For partial modifications, prefer edit_file instead. Working directory: \(workingDirectory).",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Absolute or relative path where to write the file"),
                    "content": .string(description: "Content to write to the file")
                ],
                required: ["path", "content"]
            ),
            annotations: ToolAnnotations(
                title: "Write File",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(WriteFileInput.self, from: data)
            let validPath = try self.validatePath(input.path)

            // 既存ファイルの上書きには事前の read が必要
            if self.fileManager.fileExists(atPath: validPath) && !self.hasRead(validPath) {
                throw FileSystemToolKitError.readRequired(path: validPath, tool: "write_file")
            }

            // 親ディレクトリを作成
            let parentDir = URL(fileURLWithPath: validPath).deletingLastPathComponent().path
            try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

            // ファイルを書き込み
            guard let data = input.content.data(using: .utf8) else {
                throw FileSystemToolKitError.encodingError(path: validPath)
            }
            try data.write(to: URL(fileURLWithPath: validPath))

            return .text("Successfully wrote to \(validPath)")
        }
    }

    /// edit_file ツール
    private var editFileTool: BuiltInTool {
        BuiltInTool(
            name: "edit_file",
            description: "Make precise text replacements in a file. IMPORTANT: You must use read_file before editing — this tool will fail otherwise. Finds the exact `old_string` and replaces it with `new_string`. The edit will fail if `old_string` is not unique in the file (provide more surrounding context to make it unique), unless `replace_all` is true.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Path to the file to edit"),
                    "old_string": .string(description: "The exact text to find and replace"),
                    "new_string": .string(description: "The text to replace it with"),
                    "replace_all": .boolean(description: "Replace all occurrences (default: false). Use for renaming variables or updating repeated patterns.")
                ],
                required: ["path", "old_string", "new_string"]
            ),
            annotations: ToolAnnotations(
                title: "Edit File",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(EditFileInput.self, from: data)
            let validPath = try self.validatePath(input.path)

            // edit は必ず既存ファイルを編集するため、事前の read を無条件で要求
            if !self.hasRead(validPath) {
                throw FileSystemToolKitError.readRequired(path: validPath, tool: "edit_file")
            }

            guard let fileData = self.fileManager.contents(atPath: validPath) else {
                throw FileSystemToolKitError.fileNotFound(path: validPath)
            }

            guard var content = String(data: fileData, encoding: .utf8) else {
                throw FileSystemToolKitError.encodingError(path: validPath)
            }

            let replaceAll = input.replaceAll ?? false

            // old_string の出現回数をチェック
            let occurrences = content.components(separatedBy: input.oldString).count - 1

            guard occurrences > 0 else {
                throw FileSystemToolKitError.operationFailed(
                    message: "old_string not found in \(validPath). Make sure the text matches exactly, including whitespace and indentation."
                )
            }

            if !replaceAll && occurrences > 1 {
                throw FileSystemToolKitError.operationFailed(
                    message: "old_string found \(occurrences) times in \(validPath). Provide more surrounding context to make it unique, or set replace_all to true."
                )
            }

            guard input.oldString != input.newString else {
                throw FileSystemToolKitError.operationFailed(
                    message: "old_string and new_string are identical. No changes needed."
                )
            }

            // 置換を実行
            let oldLineCount = content.components(separatedBy: "\n").count
            if replaceAll {
                content = content.replacingOccurrences(of: input.oldString, with: input.newString)
            } else {
                // 最初の出現のみ置換
                if let range = content.range(of: input.oldString) {
                    content = content.replacingCharacters(in: range, with: input.newString)
                }
            }
            let newLineCount = content.components(separatedBy: "\n").count

            // 書き戻し
            guard let writeData = content.data(using: .utf8) else {
                throw FileSystemToolKitError.encodingError(path: validPath)
            }
            try writeData.write(to: URL(fileURLWithPath: validPath))

            let lineDiff = newLineCount - oldLineCount
            let lineDiffStr = lineDiff > 0 ? "+\(lineDiff)" : "\(lineDiff)"
            let replacedCount = replaceAll ? occurrences : 1

            return .text("Edited \(validPath): \(replacedCount) replacement(s), \(lineDiffStr) lines")
        }
    }

    /// create_directory ツール
    private var createDirectoryTool: BuiltInTool {
        BuiltInTool(
            name: "create_directory",
            description: "Create a new directory or ensure a directory exists. Creates parent directories if needed.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Path of the directory to create")
                ],
                required: ["path"]
            ),
            annotations: ToolAnnotations(
                title: "Create Directory",
                readOnlyHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(CreateDirectoryInput.self, from: data)
            let validPath = try validatePath(input.path)

            try fileManager.createDirectory(atPath: validPath, withIntermediateDirectories: true)

            return .text("Successfully created directory \(validPath)")
        }
    }

    /// list_directory ツール
    private var listDirectoryTool: BuiltInTool {
        BuiltInTool(
            name: "list_directory",
            description: "Get a detailed listing of all files and directories in a specified path. Working directory: \(workingDirectory). Use '.' to list the working directory.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Absolute or relative path of the directory to list")
                ],
                required: ["path"]
            ),
            annotations: ToolAnnotations(
                title: "List Directory",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(ListDirectoryInput.self, from: data)
            let validPath = try validatePath(input.path)

            let contents = try fileManager.contentsOfDirectory(atPath: validPath)
            var entries: [DirectoryEntry] = []

            for item in contents.sorted() {
                let itemPath = (validPath as NSString).appendingPathComponent(item)
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: itemPath, isDirectory: &isDirectory)
                entries.append(DirectoryEntry(
                    name: item,
                    type: isDirectory.boolValue ? "directory" : "file"
                ))
            }

            let output = try JSONEncoder().encode(entries)
            return .json(output)
        }
    }

    /// directory_tree ツール
    private var directoryTreeTool: BuiltInTool {
        BuiltInTool(
            name: "directory_tree",
            description: "Get a recursive tree view of files and directories. Useful for understanding project structure. Working directory: \(workingDirectory). Use '.' to explore the working directory.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Absolute or relative path of the directory to explore"),
                    "maxDepth": .integer(description: "Maximum depth to traverse (default: 3, max: 10)")
                ],
                required: ["path"]
            ),
            annotations: ToolAnnotations(
                title: "Directory Tree",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(DirectoryTreeInput.self, from: data)
            let validPath = try validatePath(input.path)
            let maxDepth = min(input.maxDepth ?? 3, 10)

            let tree = buildDirectoryTree(path: validPath, depth: 0, maxDepth: maxDepth)
            let output = try JSONEncoder().encode(tree)
            return .json(output)
        }
    }

    /// move_file ツール
    private var moveFileTool: BuiltInTool {
        BuiltInTool(
            name: "move_file",
            description: "Move or rename files and directories. Both source and destination must be within allowed paths.",
            inputSchema: .object(
                properties: [
                    "source": .string(description: "Source path of the file or directory"),
                    "destination": .string(description: "Destination path")
                ],
                required: ["source", "destination"]
            ),
            annotations: ToolAnnotations(
                title: "Move File",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(MoveFileInput.self, from: data)
            let validSource = try validatePath(input.source)
            let validDest = try validatePath(input.destination)

            try fileManager.moveItem(atPath: validSource, toPath: validDest)

            return .text("Successfully moved \(validSource) to \(validDest)")
        }
    }

    /// search_files ツール
    private var searchFilesTool: BuiltInTool {
        BuiltInTool(
            name: "search_files",
            description: "Search for files matching a pattern. Supports glob patterns like *.swift or **/*.md",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Starting directory for search"),
                    "pattern": .string(description: "File name pattern to match (e.g., '*.swift', 'README*')"),
                    "recursive": .boolean(description: "Search subdirectories recursively (default: true)")
                ],
                required: ["path", "pattern"]
            ),
            annotations: ToolAnnotations(
                title: "Search Files",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(SearchFilesInput.self, from: data)
            let validPath = try validatePath(input.path)
            let recursive = input.recursive ?? true

            var matches: [String] = []
            let regex = globToRegex(input.pattern)

            if recursive {
                if let enumerator = fileManager.enumerator(atPath: validPath) {
                    while let item = enumerator.nextObject() as? String {
                        let fileName = (item as NSString).lastPathComponent
                        if fileName.range(of: regex, options: .regularExpression) != nil {
                            matches.append(item)
                        }
                    }
                }
            } else {
                let contents = try fileManager.contentsOfDirectory(atPath: validPath)
                for item in contents {
                    if item.range(of: regex, options: .regularExpression) != nil {
                        matches.append(item)
                    }
                }
            }

            let result = SearchResult(
                path: validPath,
                pattern: input.pattern,
                matches: matches.sorted()
            )
            let output = try JSONEncoder().encode(result)
            return .json(output)
        }
    }

    /// grep_files ツール
    private var grepFilesTool: BuiltInTool {
        BuiltInTool(
            name: "grep_files",
            description: "Search file contents using a regular expression pattern. Returns matching lines with file paths and line numbers. Skips binary files automatically. Default search path: \(workingDirectory).",
            inputSchema: .object(
                properties: [
                    "pattern": .string(description: "Regular expression pattern to search for"),
                    "path": .string(description: "Directory to search in (default: working directory)"),
                    "glob": .string(description: "File name filter pattern (e.g., '*.swift', '*.ts')"),
                    "context_lines": .integer(description: "Number of context lines before and after each match (default: 0)"),
                    "max_results": .integer(description: "Maximum number of matches to return (default: 100)")
                ],
                required: ["pattern"]
            ),
            annotations: ToolAnnotations(
                title: "Grep Files",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(GrepFilesInput.self, from: data)
            let searchPath: String
            if let inputPath = input.path {
                searchPath = try validatePath(inputPath)
            } else {
                searchPath = workingDirectory
            }

            let maxResults = min(input.maxResults ?? 100, 500)
            let contextLines = min(input.contextLines ?? 0, 10)

            guard let regex = try? NSRegularExpression(pattern: input.pattern, options: []) else {
                throw FileSystemToolKitError.operationFailed(
                    message: "Invalid regular expression: \(input.pattern)"
                )
            }

            let globRegex: NSRegularExpression?
            if let glob = input.glob {
                let globPattern = globToRegex(glob)
                globRegex = try? NSRegularExpression(pattern: globPattern, options: [])
            } else {
                globRegex = nil
            }

            var matches: [GrepMatch] = []

            guard let enumerator = fileManager.enumerator(atPath: searchPath) else {
                throw FileSystemToolKitError.operationFailed(
                    message: "Cannot enumerate directory: \(searchPath)"
                )
            }

            while let relativePath = enumerator.nextObject() as? String {
                guard matches.count < maxResults else { break }

                let fileName = (relativePath as NSString).lastPathComponent

                // 隠しファイル・ディレクトリをスキップ
                if fileName.hasPrefix(".") {
                    enumerator.skipDescendants()
                    continue
                }

                // glob フィルタ
                if let globRegex {
                    let range = NSRange(fileName.startIndex..., in: fileName)
                    if globRegex.firstMatch(in: fileName, range: range) == nil {
                        continue
                    }
                }

                let fullPath = (searchPath as NSString).appendingPathComponent(relativePath)

                // ディレクトリはスキップ
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    continue
                }

                // ファイルを読み込み（バイナリはスキップ）
                guard let fileData = fileManager.contents(atPath: fullPath),
                      let content = String(data: fileData, encoding: .utf8) else {
                    continue
                }

                let lines = content.components(separatedBy: "\n")

                for (lineIndex, line) in lines.enumerated() {
                    guard matches.count < maxResults else { break }

                    let range = NSRange(line.startIndex..., in: line)
                    if regex.firstMatch(in: line, range: range) != nil {
                        // コンテキスト行を収集
                        var contextBefore: [String]?
                        var contextAfter: [String]?

                        if contextLines > 0 {
                            let beforeStart = max(0, lineIndex - contextLines)
                            if beforeStart < lineIndex {
                                contextBefore = Array(lines[beforeStart..<lineIndex])
                            }

                            let afterEnd = min(lines.count, lineIndex + contextLines + 1)
                            if lineIndex + 1 < afterEnd {
                                contextAfter = Array(lines[(lineIndex + 1)..<afterEnd])
                            }
                        }

                        matches.append(GrepMatch(
                            path: relativePath,
                            lineNumber: lineIndex + 1,
                            line: line,
                            contextBefore: contextBefore,
                            contextAfter: contextAfter
                        ))
                    }
                }
            }

            let result = GrepResult(
                searchPath: searchPath,
                pattern: input.pattern,
                matchCount: matches.count,
                truncated: matches.count >= maxResults,
                matches: matches
            )
            let output = try JSONEncoder().encode(result)
            return .json(output)
        }
    }

    /// get_file_info ツール
    private var getFileInfoTool: BuiltInTool {
        BuiltInTool(
            name: "get_file_info",
            description: "Get detailed information about a file or directory including size, permissions, and timestamps.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Path to the file or directory")
                ],
                required: ["path"]
            ),
            annotations: ToolAnnotations(
                title: "Get File Info",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(GetFileInfoInput.self, from: data)
            let validPath = try validatePath(input.path)

            let attributes = try fileManager.attributesOfItem(atPath: validPath)

            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: validPath, isDirectory: &isDirectory)

            let info = FileInfo(
                path: validPath,
                type: isDirectory.boolValue ? "directory" : "file",
                size: attributes[.size] as? Int64 ?? 0,
                created: (attributes[.creationDate] as? Date)?.iso8601String,
                modified: (attributes[.modificationDate] as? Date)?.iso8601String,
                permissions: String(format: "%o", (attributes[.posixPermissions] as? Int) ?? 0),
                isReadable: fileManager.isReadableFile(atPath: validPath),
                isWritable: fileManager.isWritableFile(atPath: validPath)
            )

            let output = try JSONEncoder().encode(info)
            return .json(output)
        }
    }

    // MARK: - Helper Methods

    /// ディレクトリツリーを構築
    private func buildDirectoryTree(path: String, depth: Int, maxDepth: Int) -> DirectoryTreeNode {
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: path, isDirectory: &isDirectory)

        let name = (path as NSString).lastPathComponent
        var children: [DirectoryTreeNode]?

        if isDirectory.boolValue && depth < maxDepth {
            if let contents = try? fileManager.contentsOfDirectory(atPath: path) {
                children = contents.sorted().compactMap { item in
                    let itemPath = (path as NSString).appendingPathComponent(item)
                    // 隠しファイルをスキップ
                    guard !item.hasPrefix(".") else { return nil }
                    return buildDirectoryTree(path: itemPath, depth: depth + 1, maxDepth: maxDepth)
                }
            }
        }

        return DirectoryTreeNode(
            name: name,
            type: isDirectory.boolValue ? "directory" : "file",
            children: children
        )
    }

    /// グロブパターンを正規表現に変換
    private func globToRegex(_ pattern: String) -> String {
        var regex = "^"
        for char in pattern {
            switch char {
            case "*":
                regex += ".*"
            case "?":
                regex += "."
            case ".":
                regex += "\\."
            case "[", "]", "(", ")", "{", "}", "+", "^", "$", "|", "\\":
                regex += "\\\(char)"
            default:
                regex += String(char)
            }
        }
        regex += "$"
        return regex
    }
}

// MARK: - Input Types

private struct ReadFileInput: Codable {
    var path: String
}

private struct ReadMultipleFilesInput: Codable {
    var paths: [String]
}

private struct WriteFileInput: Codable {
    var path: String
    var content: String
}

private struct CreateDirectoryInput: Codable {
    var path: String
}

private struct ListDirectoryInput: Codable {
    var path: String
}

private struct DirectoryTreeInput: Codable {
    var path: String
    var maxDepth: Int?
}

private struct MoveFileInput: Codable {
    var source: String
    var destination: String
}

private struct SearchFilesInput: Codable {
    var path: String
    var pattern: String
    var recursive: Bool?
}

private struct EditFileInput: Codable {
    var path: String
    var oldString: String
    var newString: String
    var replaceAll: Bool?

    enum CodingKeys: String, CodingKey {
        case path
        case oldString = "old_string"
        case newString = "new_string"
        case replaceAll = "replace_all"
    }
}

private struct GrepFilesInput: Codable {
    var pattern: String
    var path: String?
    var glob: String?
    var contextLines: Int?
    var maxResults: Int?

    enum CodingKeys: String, CodingKey {
        case pattern, path, glob
        case contextLines = "context_lines"
        case maxResults = "max_results"
    }
}

private struct GetFileInfoInput: Codable {
    var path: String
}

// MARK: - Result Types

private struct FileReadResult: Codable {
    var path: String
    var content: String?
    var error: String?
}

private struct DirectoryEntry: Codable {
    var name: String
    var type: String
}

private struct DirectoryTreeNode: Codable {
    var name: String
    var type: String
    var children: [DirectoryTreeNode]?
}

private struct SearchResult: Codable {
    var path: String
    var pattern: String
    var matches: [String]
}

private struct GrepMatch: Codable {
    var path: String
    var lineNumber: Int
    var line: String
    var contextBefore: [String]?
    var contextAfter: [String]?

    enum CodingKeys: String, CodingKey {
        case path
        case lineNumber = "line_number"
        case line
        case contextBefore = "context_before"
        case contextAfter = "context_after"
    }
}

private struct GrepResult: Codable {
    var searchPath: String
    var pattern: String
    var matchCount: Int
    var truncated: Bool
    var matches: [GrepMatch]

    enum CodingKeys: String, CodingKey {
        case searchPath = "search_path"
        case pattern
        case matchCount = "match_count"
        case truncated, matches
    }
}

private struct FileInfo: Codable {
    var path: String
    var type: String
    var size: Int64
    var created: String?
    var modified: String?
    var permissions: String
    var isReadable: Bool
    var isWritable: Bool
}

// MARK: - Errors

/// FileSystemToolKitのエラー
public enum FileSystemToolKitError: Error, LocalizedError {
    case accessDenied(path: String, allowedPaths: [String])
    case fileNotFound(path: String)
    case encodingError(path: String)
    case operationFailed(message: String)
    case readRequired(path: String, tool: String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied(let path, let allowedPaths):
            return "Access denied to '\(path)'. Allowed paths: \(allowedPaths.joined(separator: ", "))"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .encodingError(let path):
            return "Could not read file as UTF-8: \(path)"
        case .operationFailed(let message):
            return message
        case .readRequired(let path, let tool):
            return "Cannot \(tool) '\(path)' without reading it first. Use read_file to read the file, then retry \(tool)."
        }
    }
}

// MARK: - Date Extension

private extension Date {
    nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = ISO8601DateFormatter()

    var iso8601String: String {
        Self.iso8601Formatter.string(from: self)
    }
}
