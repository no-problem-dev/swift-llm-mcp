import Foundation
import LLMClient
import LLMTool

// MARK: - FileSystemToolKit

/// File system tools for the model: read, write, edit, list, search and move.
///
/// Follows the official MCP Filesystem Server's tool set. Two safeguards are worth knowing
/// before you wire it up:
///
/// - **`allowedPaths` is the only boundary.** Leaving it `nil` grants every path this
///   process can reach. On iOS that is the app sandbox, which is a real limit; on macOS it
///   is the user's whole home directory, which is not.
/// - **Overwriting requires reading first.** `write_file` on an existing file and
///   `edit_file` on any file both fail unless that exact path was read in this session, so
///   the model cannot destroy a file it has not seen.
///
/// The tools are: `read_file`, `read_multiple_files`, `write_file`, `edit_file`,
/// `create_directory`, `list_directory`, `directory_tree`, `move_file`, `search_files`,
/// `grep_files` and `get_file_info`.
///
/// ```swift
/// // iOS: the sandbox is the boundary, Documents is the working directory
/// let tools = ToolSet {
///     FileSystemToolKit()
/// }
///
/// // macOS: name the directories explicitly
/// let tools = ToolSet {
///     FileSystemToolKit(
///         allowedPaths: ["/Users/user/projects"],
///         workingDirectory: "/Users/user/projects"
///     )
/// }
/// ```
public final class FileSystemToolKit: ToolKit, @unchecked Sendable {
    // MARK: - Properties

    public let name: String = "filesystem"

    /// Paths the model may touch, already tilde-expanded. `nil` allows everything.
    private let allowedPaths: [String]?

    /// Where relative paths resolve. Its value is written into every tool's description, so
    /// the model can see which directory it is standing in.
    private let workingDirectory: String

    private let fileManager: FileManager

    /// Paths read during this session, which is what `write_file` and `edit_file` check
    /// before they will overwrite anything.
    ///
    /// Grows for the lifetime of the kit and is never pruned; a long session accumulates one
    /// string per file read.
    private let readPaths = LockedValue(initialState: Set<String>())

    // MARK: - Initialization

    /// Creates the kit.
    ///
    /// - Parameters:
    ///   - allowedPaths: Directories the model may work in. A leading `~` is expanded.
    ///     `nil` imposes no boundary of its own, which is reasonable on iOS where the
    ///     sandbox is the boundary, and is not on macOS.
    ///   - workingDirectory: Where relative paths resolve. Defaults to the app's Documents
    ///     directory. It is not required to be inside `allowedPaths`, and a relative path
    ///     that resolves outside them is still rejected.
    public init(allowedPaths: [String]? = nil, workingDirectory: String? = nil) {
        self.allowedPaths = allowedPaths?.map { path in
            NSString(string: path).expandingTildeInPath
        }
        self.workingDirectory = workingDirectory ?? Self.defaultWorkingDirectory
        self.fileManager = FileManager.default
    }

    /// Creates a kit confined to one session's workspace.
    ///
    /// The preferred initializer, because it cannot be configured into an unbounded state:
    /// the allowed paths are the workspace root plus its declared extras, and nothing else.
    ///
    /// - Parameter workspace: Supplies both the boundary and the working directory.
    public convenience init(workspace: Workspace) {
        self.init(
            allowedPaths: [workspace.rootDirectory] + workspace.additionalAllowedPaths,
            workingDirectory: workspace.workingDirectory
        )
    }

    /// The app's Documents directory, or the process's current directory if there is none.
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

    /// Resolves a path to an absolute one and rejects it if it falls outside ``allowedPaths``.
    ///
    /// Anything not starting with `/` resolves against ``workingDirectory``, so `"."` gives
    /// the working directory itself. `..` segments are collapsed before the check, so they
    /// cannot be used to climb out.
    ///
    /// Two limits on how tight the boundary really is. The comparison is a string prefix
    /// rather than a path-component one, so allowing `/data` also allows `/database`. And
    /// symlinks are not resolved, so a link inside an allowed directory pointing outside it
    /// is followed.
    ///
    /// - Throws: ``FileSystemToolKitError/accessDenied(path:allowedPaths:)``.
    private func validatePath(_ path: String) throws -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath

        let absolutePath: String
        if expandedPath.hasPrefix("/") {
            absolutePath = expandedPath
        } else {
            absolutePath = (workingDirectory as NSString).appendingPathComponent(expandedPath)
        }

        let resolvedPath = URL(fileURLWithPath: absolutePath).standardizedFileURL.path

        // No list means no boundary.
        guard let allowedPaths else { return resolvedPath }

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

    /// The `read_file` tool: return a file's whole contents and mark it readable for editing.
    ///
    /// The whole file is loaded into memory and there is no size cap, so a large file goes
    /// straight into the model's context. Only UTF-8 decodes; anything else fails rather
    /// than returning bytes.
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

    /// The `read_multiple_files` tool: read several files in one call.
    ///
    /// Per-file failures are reported inside the result rather than thrown, so one denied or
    /// binary file does not lose the others. Files are read sequentially and every successful
    /// one is marked readable for editing.
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

    /// The `write_file` tool: create a file, or replace an existing one entirely.
    ///
    /// Overwriting an existing file requires that exact path to have been read first;
    /// creating a new one does not. Missing parent directories are created. The write is not
    /// atomic, so an interrupted call can leave a partially written file.
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

            // Creating is free; destroying is not. Only an overwrite needs a prior read.
            if self.fileManager.fileExists(atPath: validPath) && !self.hasRead(validPath) {
                throw FileSystemToolKitError.readRequired(path: validPath, tool: "write_file")
            }

            let parentDir = URL(fileURLWithPath: validPath).deletingLastPathComponent().path
            try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

            guard let data = input.content.data(using: .utf8) else {
                throw FileSystemToolKitError.encodingError(path: validPath)
            }
            try data.write(to: URL(fileURLWithPath: validPath))

            return .text("Successfully wrote to \(validPath)")
        }
    }

    /// The `edit_file` tool: replace an exact string in a file.
    ///
    /// Requires a prior read of that path, unconditionally. A non-unique `old_string` is
    /// refused unless `replace_all` is set, which is what stops the model from editing the
    /// wrong occurrence. Matching is literal, not regular-expression, and the whole file is
    /// read and rewritten.
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

            // Editing always modifies an existing file, so the read requirement has no exception.
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

            // Count first: an ambiguous match must be refused, not resolved arbitrarily.
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

            // Line counts bracket the edit so the result can report the net line change.
            let oldLineCount = content.components(separatedBy: "\n").count
            if replaceAll {
                content = content.replacingOccurrences(of: input.oldString, with: input.newString)
            } else {
                // Exactly one occurrence exists at this point, so this is unambiguous.
                if let range = content.range(of: input.oldString) {
                    content = content.replacingCharacters(in: range, with: input.newString)
                }
            }
            let newLineCount = content.components(separatedBy: "\n").count

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

    /// The `create_directory` tool: create a directory and any missing parents.
    ///
    /// Succeeds on a directory that already exists, so it is safe to call repeatedly.
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

    /// The `list_directory` tool: one level of names, each tagged file or directory.
    ///
    /// Includes hidden entries, unlike `directory_tree` and `grep_files`, and lists every
    /// entry with no cap. Names are sorted; sizes and dates are not included.
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

    /// The `directory_tree` tool: a recursive view for understanding project layout.
    ///
    /// Depth defaults to 3 and is clamped to 10, which is what keeps a deep tree from
    /// filling the context window. Hidden entries are skipped, and there is no cap on how
    /// many entries a single level may contribute.
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

    /// The `move_file` tool: move or rename, with both ends checked against the allowed paths.
    ///
    /// No prior read is required, so this is the one way the model can relocate a file it
    /// has never opened. Fails rather than overwriting when the destination exists.
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

    /// The `search_files` tool: find files whose name matches a glob.
    ///
    /// The glob is matched against the file name only, never the directory part, so `**/`
    /// in a pattern has no effect. Results are relative paths when recursive and bare names
    /// when not. Hidden files are included, and there is no result cap.
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

    /// The `grep_files` tool: search file contents by regular expression.
    ///
    /// Results are capped at 100 by default and 500 absolutely, with `truncated` in the
    /// result telling the model whether it saw everything. Context lines are capped at 10
    /// each side. Hidden directories are pruned wholesale, and files that do not decode as
    /// UTF-8 are skipped, which is how binaries are excluded.
    ///
    /// Every candidate file is read into memory in full and split into lines, so a directory
    /// of very large files is expensive even when nothing matches.
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

                // Prune the whole subtree, so .git and node_modules cost nothing.
                if fileName.hasPrefix(".") {
                    enumerator.skipDescendants()
                    continue
                }

                if let globRegex {
                    let range = NSRange(fileName.startIndex..., in: fileName)
                    if globRegex.firstMatch(in: fileName, range: range) == nil {
                        continue
                    }
                }

                let fullPath = (searchPath as NSString).appendingPathComponent(relativePath)

                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    continue
                }

                // Failure to decode as UTF-8 is the binary-file test.
                guard let fileData = fileManager.contents(atPath: fullPath),
                      let content = String(data: fileData, encoding: .utf8) else {
                    continue
                }

                let lines = content.components(separatedBy: "\n")

                for (lineIndex, line) in lines.enumerated() {
                    guard matches.count < maxResults else { break }

                    let range = NSRange(line.startIndex..., in: line)
                    if regex.firstMatch(in: line, range: range) != nil {
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

    /// The `get_file_info` tool: size, timestamps, POSIX permissions and readability.
    ///
    /// Lets the model check a file's size before reading it, since `read_file` has no cap.
    /// Fails on a path that does not exist rather than reporting absence.
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

    /// Builds one tree node, recursing until `maxDepth`.
    ///
    /// A directory that cannot be listed yields a node with no children rather than an
    /// error, so an unreadable subtree is indistinguishable from an empty one.
    private func buildDirectoryTree(path: String, depth: Int, maxDepth: Int) -> DirectoryTreeNode {
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: path, isDirectory: &isDirectory)

        let name = (path as NSString).lastPathComponent
        var children: [DirectoryTreeNode]?

        if isDirectory.boolValue && depth < maxDepth {
            if let contents = try? fileManager.contentsOfDirectory(atPath: path) {
                children = contents.sorted().compactMap { item in
                    let itemPath = (path as NSString).appendingPathComponent(item)
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

    /// Turns a glob into an anchored regular expression.
    ///
    /// Handles `*` and `?` only. `/` is not special, so `**` is just two wildcards and
    /// cannot express "any number of directories" — which is why callers match the file
    /// name rather than the path.
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

/// Failures from ``FileSystemToolKit``.
///
/// Each `errorDescription` names the fix, because it is read by a model choosing its next
/// tool call — ``readRequired(path:tool:)`` in particular tells it to call `read_file` first.
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


// MARK: - LockedValue

/// A value guarded by a lock, standing in for `OSAllocatedUnfairLock`, which exists only on
/// Apple's platforms.
///
/// `Mutex` from the `Synchronization` module would be the direct replacement, but it needs
/// macOS 15 / iOS 18 and this package supports macOS 14 / iOS 17.
private final class LockedValue<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(initialState value: Value) {
        self.value = value
    }

    /// Runs `body` with exclusive access to the value. Do not call back into the same
    /// instance from inside `body`; `NSLock` is not recursive and doing so deadlocks.
    @discardableResult
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
