import Foundation

// MARK: - Workspace

/// The area of the file system one agent session may work in.
///
/// Two directories, doing two different jobs: `workingDirectory` is where relative paths
/// resolve, and `rootDirectory` is the boundary a policy tests paths against. They are
/// often the same directory, but they need not be.
///
/// ```
/// rootDirectory/           <- the boundary; file operations inside are allowed
///   └── workingDirectory/  <- where relative paths resolve
///       ├── output/
///       └── data/
/// ```
public struct Workspace: Sendable, Identifiable, Equatable {
    /// Identifies the workspace. ``WorkspaceProvider`` sets it to the session id.
    public let id: UUID

    /// Where relative paths resolve.
    public let workingDirectory: String

    /// The boundary. A policy allows file operations under this path and asks the user
    /// about anything outside it.
    public let rootDirectory: String

    /// Extra paths a policy allows despite being outside ``rootDirectory``.
    ///
    /// For places a session genuinely needs but that do not belong inside its workspace,
    /// such as shared session storage. Every entry widens the boundary, so keep the list short.
    public let additionalAllowedPaths: [String]

    /// Whether this workspace was created automatically or named by the user.
    public let source: WorkspaceSource

    public init(
        id: UUID = UUID(),
        workingDirectory: String,
        rootDirectory: String,
        source: WorkspaceSource = .automatic,
        additionalAllowedPaths: [String] = []
    ) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.rootDirectory = rootDirectory
        self.source = source
        self.additionalAllowedPaths = additionalAllowedPaths
    }
}

// MARK: - WorkspaceSource

/// Where a workspace came from, which decides whether deleting it is safe.
public enum WorkspaceSource: Sendable, Equatable {
    /// Created by ``WorkspaceProvider`` under its base directory, and safe to delete with the session.
    case automatic

    /// A directory the user chose. It holds their own files, so it outlives the session.
    case userSpecified(path: String)
}
