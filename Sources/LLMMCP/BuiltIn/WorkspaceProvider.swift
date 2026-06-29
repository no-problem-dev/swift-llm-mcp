import Foundation

// MARK: - WorkspaceProvider

/// ワークスペースのライフサイクル管理
///
/// セッションごとのワークスペースを作成・取得・削除する。
/// セッション開始時に `createWorkspace(for:)` で作成し、
/// セッション終了時に `removeWorkspace(for:)` で削除する。
///
/// ## 使用例
///
/// ```swift
/// let provider = WorkspaceProvider()
///
/// // セッション開始時
/// let workspace = try await provider.createWorkspace(for: sessionId)
///
/// // ツールに渡す
/// let fileSystem = FileSystemToolKit(workspace: workspace)
/// let policy = WorkspaceExecutionPolicy(workspace: workspace)
///
/// // セッション終了時
/// await provider.removeWorkspace(for: sessionId)
/// ```
public actor WorkspaceProvider {
    /// セッション ID → Workspace のマッピング
    private var workspaces: [UUID: Workspace] = [:]

    /// ワークスペースのベースディレクトリ
    private let baseDirectory: String

    /// FileManager
    private let fileManager: FileManager

    public init(baseDirectory: String? = nil) {
        self.baseDirectory = baseDirectory ?? Self.defaultBaseDirectory
        self.fileManager = FileManager.default
    }

    /// セッション用のワークスペースを作成
    ///
    /// - Parameter sessionId: セッション ID
    /// - Returns: 作成されたワークスペース
    /// - Throws: ディレクトリ作成に失敗した場合
    public func createWorkspace(for sessionId: UUID) throws -> Workspace {
        let rootDir = (baseDirectory as NSString).appendingPathComponent(sessionId.uuidString)
        let workDir = rootDir

        try fileManager.createDirectory(atPath: rootDir, withIntermediateDirectories: true)

        let workspace = Workspace(
            id: sessionId,
            workingDirectory: workDir,
            rootDirectory: rootDir,
            source: .automatic
        )
        workspaces[sessionId] = workspace
        return workspace
    }

    /// セッションのワークスペースを取得
    ///
    /// - Parameter sessionId: セッション ID
    /// - Returns: 存在する場合はワークスペース
    public func workspace(for sessionId: UUID) -> Workspace? {
        workspaces[sessionId]
    }

    /// セッションのワークスペースを削除
    ///
    /// インメモリ辞書にエントリがある場合はそのパスを使用し、
    /// ない場合は `baseDirectory/{sessionId}` から直接削除を試みる。
    /// これにより、前回起動で作成されたワークスペースや、
    /// 一度も activate されなかったセッションのディレクトリも確実に削除される。
    ///
    /// - Parameter sessionId: セッション ID
    public func removeWorkspace(for sessionId: UUID) {
        if let workspace = workspaces.removeValue(forKey: sessionId) {
            try? fileManager.removeItem(atPath: workspace.rootDirectory)
        } else {
            // 辞書になくてもパスから直接削除を試みる
            let rootDir = (baseDirectory as NSString)
                .appendingPathComponent(sessionId.uuidString)
            if fileManager.fileExists(atPath: rootDir) {
                try? fileManager.removeItem(atPath: rootDir)
            }
        }
    }

    /// 全ワークスペースを削除
    public func removeAll() {
        for workspace in workspaces.values {
            try? fileManager.removeItem(atPath: workspace.rootDirectory)
        }
        workspaces.removeAll()
    }

    /// デフォルトのベースディレクトリ
    private static var defaultBaseDirectory: String {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docsDir.appendingPathComponent("Sessions").path
    }
}
