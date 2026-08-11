import Foundation

// MARK: - WorkspaceProvider

/// Creates and deletes one directory per agent session.
///
/// Create at the start of a session, delete at the end. The in-memory map lives only as
/// long as this actor, so a process that exits without deleting leaves the directories on
/// disk — ``removeWorkspace(for:)`` can still clean those up from the session id alone.
///
/// ```swift
/// let provider = WorkspaceProvider()
///
/// let workspace = try await provider.createWorkspace(for: sessionId)
///
/// let fileSystem = FileSystemToolKit(workspace: workspace)
/// let policy = WorkspaceExecutionPolicy(workspace: workspace)
///
/// await provider.removeWorkspace(for: sessionId)
/// ```
public actor WorkspaceProvider {
    private var workspaces: [UUID: Workspace] = [:]

    private let baseDirectory: String

    private let fileManager: FileManager

    /// Creates a provider. No directory is touched until ``createWorkspace(for:)``.
    ///
    /// - Parameter baseDirectory: Parent for every session directory. Defaults to
    ///   `Documents/Sessions`. Deletion is scoped to this directory, so pointing it at a
    ///   directory holding other files puts them within reach of ``removeAll()``.
    public init(baseDirectory: String? = nil) {
        self.baseDirectory = baseDirectory ?? Self.defaultBaseDirectory
        self.fileManager = FileManager.default
    }

    /// Creates `baseDirectory/<sessionId>` and registers a workspace rooted there.
    ///
    /// Idempotent on disk — an existing directory is reused with its contents intact — but
    /// it replaces any previously registered workspace for the same session id.
    ///
    /// - Parameter sessionId: Also becomes the workspace id and the directory name.
    /// - Throws: A `FileManager` error when the directory cannot be created.
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

    /// The workspace this provider created for a session, or `nil` if it created none.
    ///
    /// Reads the in-memory map only, so a directory left behind by a previous process is
    /// reported as absent even though it exists on disk.
    public func workspace(for sessionId: UUID) -> Workspace? {
        workspaces[sessionId]
    }

    /// Deletes a session's directory and everything in it.
    ///
    /// Works from the registered workspace when there is one, and otherwise from
    /// `baseDirectory/<sessionId>` directly — which is what lets it reclaim directories
    /// left by an earlier process run, or by a session that was never used.
    ///
    /// Deletion failures are swallowed, so this reports nothing whether it removed
    /// something, found nothing, or was denied permission.
    ///
    /// - Parameter sessionId: Session whose directory should go.
    public func removeWorkspace(for sessionId: UUID) {
        if let workspace = workspaces.removeValue(forKey: sessionId) {
            try? fileManager.removeItem(atPath: workspace.rootDirectory)
        } else {
            // Not registered here, but the directory may still exist from an earlier run.
            let rootDir = (baseDirectory as NSString)
                .appendingPathComponent(sessionId.uuidString)
            if fileManager.fileExists(atPath: rootDir) {
                try? fileManager.removeItem(atPath: rootDir)
            }
        }
    }

    /// Deletes every workspace this provider registered, and forgets them.
    ///
    /// Covers only what is in memory, so directories from earlier process runs survive.
    public func removeAll() {
        for workspace in workspaces.values {
            try? fileManager.removeItem(atPath: workspace.rootDirectory)
        }
        workspaces.removeAll()
    }

    /// `Documents/Sessions`. Traps if the Documents directory cannot be resolved.
    private static var defaultBaseDirectory: String {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docsDir.appendingPathComponent("Sessions").path
    }
}
