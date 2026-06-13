import Foundation
import HTTPTransport
import StructuredDataCore
import JSONParsing
import JavaScriptCore
import LLMClient
import LLMTool

// MARK: - ScriptToolKit

/// JavaScriptCore ベースのスクリプト実行ツールを提供するToolKit
///
/// LLM が生成した JavaScript コードをサンドボックス内で実行します。
/// Swift ブリッジを通じて iOS API（ファイル操作・HTTP リクエスト等）へのアクセスを提供します。
///
/// ## 使用例
///
/// ```swift
/// let tools = ToolSet {
///     ScriptToolKit(
///         bridge: ScriptBridge(allowedPaths: ["/Users/user/Documents"]),
///         timeout: 30
///     )
/// }
/// ```
///
/// ## 提供されるツール
///
/// - `run_script`: JavaScript コードを実行し結果を返す
public final class ScriptToolKit: ToolKit, @unchecked Sendable {
    // MARK: - Properties

    public let name: String = "script"

    /// Swift ブリッジ（JS に公開する API）
    private let bridge: ScriptBridge

    /// スクリプト実行のタイムアウト（秒）
    private let timeout: TimeInterval

    // MARK: - Initialization

    /// ScriptToolKitを作成
    ///
    /// - Parameters:
    ///   - bridge: JS に公開する Swift API のブリッジ
    ///   - timeout: スクリプト実行のタイムアウト秒数（デフォルト: 30）
    public init(
        bridge: ScriptBridge = ScriptBridge(),
        timeout: TimeInterval = 30
    ) {
        self.bridge = bridge
        self.timeout = timeout
    }

    // MARK: - ToolKit Protocol

    public var tools: [any Tool] {
        [runScriptTool]
    }

    // MARK: - Tool Definition

    /// run_script ツール
    private var runScriptTool: BuiltInTool {
        BuiltInTool(
            name: "run_script",
            description: """
                Execute JavaScript code in a sandboxed environment. \
                Use this for data processing, text transformation, calculations, \
                or any task that requires custom logic beyond what other tools provide. \
                The `ios` object provides bridged APIs: \
                `ios.cwd` (working directory path string), \
                `ios.readFile(path)`, `ios.writeFile(path, content)`, `ios.listFiles(path)`, \
                `ios.fetch(url)`, `ios.log(message)`. \
                Relative paths in file APIs are resolved against `ios.cwd`. \
                The return value of the last expression is captured as the result.
                """,
            inputSchema: .object(
                properties: [
                    "code": .string(
                        description: "JavaScript code to execute. The return value of the last expression becomes the result."
                    ),
                ],
                required: ["code"]
            ),
            annotations: ToolAnnotations(
                title: "Run Script",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { [self] data in
            let input = try JSONDecoder().decode(RunScriptInput.self, from: data)

            // タイムアウト付きで実行
            return try await withThrowingTaskGroup(of: ToolResult.self) { group in
                group.addTask { [self] in
                    try await self.executeScript(code: input.code)
                }

                group.addTask { [self] in
                    try await Task.sleep(for: .seconds(self.timeout))
                    throw ScriptToolKitError.timeout(seconds: self.timeout)
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        }
    }

    // MARK: - Script Execution

    /// JavaScript コードを実行
    private func executeScript(code: String) async throws -> ToolResult {
        // JSContext はメインスレッドで作成・操作する必要はないが、
        // 同一スレッドで作成・評価を行う
        let vm = JSVirtualMachine()!
        let context = JSContext(virtualMachine: vm)!

        // ログバッファ
        let logBuffer = LogBuffer()

        // 例外ハンドラ
        var scriptError: String?
        context.exceptionHandler = { _, exception in
            scriptError = exception?.toString() ?? "Unknown JavaScript error"
        }

        // ブリッジ API を注入
        bridge.install(into: context, logBuffer: logBuffer)

        // console.log を提供
        installConsole(into: context, logBuffer: logBuffer)

        // スクリプトを実行
        let result = context.evaluateScript(code)

        // エラーチェック
        if let error = scriptError {
            return .error("Script error: \(error)")
        }

        // 結果を組み立て
        var output = ""

        // ログ出力があれば先に追加
        let logs = logBuffer.flush()
        if !logs.isEmpty {
            output += logs.joined(separator: "\n")
            output += "\n"
        }

        // 戻り値を追加
        if let result, !result.isUndefined, !result.isNull {
            let resultString: String
            if result.isObject, let object = result.toObject() {
                resultString = JSONSerializer(options: .init(prettyPrinted: true, sortKeys: true))
                    .string(from: StructuredValue(anyValue: object))
            } else {
                resultString = result.toString()
            }
            output += resultString
        }

        if output.isEmpty {
            return .text("(no output)")
        }

        return .text(output)
    }

    /// console オブジェクトを JSContext に注入
    private func installConsole(into context: JSContext, logBuffer: LogBuffer) {
        let console = JSValue(newObjectIn: context)!

        let logFn: @convention(block) (JSValue) -> Void = { value in
            logBuffer.append(value.toString())
        }

        let warnFn: @convention(block) (JSValue) -> Void = { value in
            logBuffer.append("[warn] \(value.toString())")
        }

        let errorFn: @convention(block) (JSValue) -> Void = { value in
            logBuffer.append("[error] \(value.toString())")
        }

        console.setObject(
            unsafeBitCast(logFn, to: AnyObject.self),
            forKeyedSubscript: "log" as NSString
        )
        console.setObject(
            unsafeBitCast(warnFn, to: AnyObject.self),
            forKeyedSubscript: "warn" as NSString
        )
        console.setObject(
            unsafeBitCast(errorFn, to: AnyObject.self),
            forKeyedSubscript: "error" as NSString
        )

        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

}

// MARK: - ScriptBridge

/// JavaScript に公開する Swift API のブリッジ
///
/// JSContext に `ios` オブジェクトとして注入され、
/// ファイル操作やHTTPリクエストなどの iOS API へのアクセスを提供します。
public final class ScriptBridge: @unchecked Sendable {
    /// アクセス許可されたパス（nil の場合は全パス許可）
    private let allowedPaths: [String]?

    /// 相対パスの基準となる作業ディレクトリ
    private let workingDirectory: String

    /// FileManager
    private let fileManager: FileManager

    /// HTTP トランスポート
    private let transport: any HTTPTransport

    /// HTTP リクエストのタイムアウト
    private let httpTimeout: TimeInterval

    /// ScriptBridge を作成
    ///
    /// - Parameters:
    ///   - allowedPaths: ファイルアクセスを許可するパスの配列（nil で全パス許可）
    ///     iOS ではサンドボックスが OS レベルで制限するため、nil で問題ありません。
    ///   - workingDirectory: 相対パスの基準ディレクトリ（nil でアプリの Documents ディレクトリ）
    ///   - httpTimeout: HTTP リクエストのタイムアウト秒数（デフォルト: 15）
    public init(
        allowedPaths: [String]? = nil,
        workingDirectory: String? = nil,
        httpTimeout: TimeInterval = 15,
        transport: (any HTTPTransport)? = nil
    ) {
        self.allowedPaths = allowedPaths?.map { path in
            NSString(string: path).expandingTildeInPath
        }
        self.workingDirectory = workingDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.currentDirectoryPath
        self.fileManager = FileManager.default

        if let transport {
            self.transport = transport
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = httpTimeout
            self.transport = URLSessionTransport(session: URLSession(configuration: config), defaultTimeout: httpTimeout)
        }

        self.httpTimeout = httpTimeout
    }

    /// パスを解決し、許可されているかチェック
    ///
    /// 相対パス（`/` で始まらないパス）は `workingDirectory` を基準に解決される。
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

        let isAllowed = allowedPaths.contains { allowedPath in
            resolvedPath.hasPrefix(allowedPath)
        }

        guard isAllowed else {
            throw ScriptToolKitError.accessDenied(path: resolvedPath)
        }

        return resolvedPath
    }

    /// JSContext に iOS ブリッジ API を注入
    func install(into context: JSContext, logBuffer: LogBuffer) {
        let ios = JSValue(newObjectIn: context)!

        // ios.cwd → String (作業ディレクトリパス)
        ios.setObject(
            workingDirectory,
            forKeyedSubscript: "cwd" as NSString
        )

        // ios.readFile(path) → String
        let readFile: @convention(block) (String) -> String = { [self] path in
            do {
                let validPath = try validatePath(path)
                guard let data = fileManager.contents(atPath: validPath),
                      let text = String(data: data, encoding: .utf8)
                else {
                    return "[error] Cannot read file: \(path)"
                }
                return text
            } catch {
                return "[error] \(error.localizedDescription)"
            }
        }

        // ios.writeFile(path, content) → Bool
        let writeFile: @convention(block) (String, String) -> Bool = { [self] path, content in
            do {
                let validPath = try validatePath(path)
                let parentDir = URL(fileURLWithPath: validPath).deletingLastPathComponent().path
                try fileManager.createDirectory(
                    atPath: parentDir,
                    withIntermediateDirectories: true
                )
                guard let data = content.data(using: .utf8) else { return false }
                try data.write(to: URL(fileURLWithPath: validPath))
                return true
            } catch {
                logBuffer.append("[error] writeFile: \(error.localizedDescription)")
                return false
            }
        }

        // ios.listFiles(path) → [String]
        let listFiles: @convention(block) (String) -> [String] = { [self] path in
            do {
                let validPath = try validatePath(path)
                return try fileManager.contentsOfDirectory(atPath: validPath).sorted()
            } catch {
                return ["[error] \(error.localizedDescription)"]
            }
        }

        // ios.fetch(url) → String
        // 注意: JSContext 内では async が使えないため、セマフォベースの同期呼び出し
        let fetch: @convention(block) (String) -> String = { [self] urlString in
            guard let url = URL(string: urlString) else {
                return "[error] Invalid URL: \(urlString)"
            }

            // nonisolated(unsafe) で Sendable 警告を回避（セマフォで同期するため安全）
            nonisolated(unsafe) var resultText = "[error] Request failed"
            let semaphore = DispatchSemaphore(value: 0)
            let transport = self.transport
            let timeout = self.httpTimeout

            Task {
                defer { semaphore.signal() }
                do {
                    let response = try await transport.send(HTTPRequest(method: "GET", url: url, timeout: timeout))
                    guard (200...299).contains(response.status) else {
                        resultText = "[error] HTTP \(response.status)"
                        return
                    }
                    resultText = String(data: response.body, encoding: .utf8) ?? "[error] Cannot decode response"
                } catch {
                    resultText = "[error] \(error.localizedDescription)"
                }
            }
            semaphore.wait()

            return resultText
        }

        // ios.log(message)
        let log: @convention(block) (String) -> Void = { message in
            logBuffer.append(message)
        }

        ios.setObject(
            unsafeBitCast(readFile, to: AnyObject.self),
            forKeyedSubscript: "readFile" as NSString
        )
        ios.setObject(
            unsafeBitCast(writeFile, to: AnyObject.self),
            forKeyedSubscript: "writeFile" as NSString
        )
        ios.setObject(
            unsafeBitCast(listFiles, to: AnyObject.self),
            forKeyedSubscript: "listFiles" as NSString
        )
        ios.setObject(
            unsafeBitCast(fetch, to: AnyObject.self),
            forKeyedSubscript: "fetch" as NSString
        )
        ios.setObject(
            unsafeBitCast(log, to: AnyObject.self),
            forKeyedSubscript: "log" as NSString
        )

        context.setObject(ios, forKeyedSubscript: "ios" as NSString)
    }
}

// MARK: - LogBuffer

/// スクリプト実行中のログを蓄積するバッファ
final class LogBuffer: @unchecked Sendable {
    private var logs: [String] = []
    private let lock = NSLock()

    func append(_ message: String) {
        lock.lock()
        logs.append(message)
        lock.unlock()
    }

    func flush() -> [String] {
        lock.lock()
        let result = logs
        logs.removeAll()
        lock.unlock()
        return result
    }
}

// MARK: - Input Types

private struct RunScriptInput: Codable {
    var code: String
}

// MARK: - Errors

/// ScriptToolKitのエラー
public enum ScriptToolKitError: Error, LocalizedError {
    case timeout(seconds: TimeInterval)
    case accessDenied(path: String)
    case executionFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let seconds):
            return "Script execution timed out after \(Int(seconds)) seconds"
        case .accessDenied(let path):
            return "Access denied to path: \(path)"
        case .executionFailed(let message):
            return "Script execution failed: \(message)"
        }
    }
}
