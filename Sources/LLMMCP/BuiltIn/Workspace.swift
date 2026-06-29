import Foundation

// MARK: - Workspace

/// セッションのワークスペース
///
/// エージェントセッションに紐づく作業領域を表す。
/// `workingDirectory` がツールの相対パス解決の基準となり、
/// `rootDirectory` がワークスペース境界（ポリシー評価の基準）となる。
///
/// ## ディレクトリ構成例
///
/// ```
/// rootDirectory/           ← ワークスペース境界（この中は自由に読み書き可能）
///   └── workingDirectory/  ← ツールの相対パス基準
///       ├── output/
///       └── data/
/// ```
public struct Workspace: Sendable, Identifiable, Equatable {
    /// ワークスペース ID
    public let id: UUID

    /// 作業ディレクトリ（ツールの相対パス基準）
    public let workingDirectory: String

    /// ルートディレクトリ（ワークスペース境界）
    ///
    /// ポリシーはこのパス内のファイル操作を自動許可し、
    /// 外部へのアクセスにはユーザー承認を要求する。
    public let rootDirectory: String

    /// 追加の許可パス
    ///
    /// ルートディレクトリ以外にもアクセスを許可するパス。
    /// セッションストレージなど、ワークスペース外だがアクセスが必要なパスに使用。
    public let additionalAllowedPaths: [String]

    /// ワークスペースのソース
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

/// ワークスペースの作成元
public enum WorkspaceSource: Sendable, Equatable {
    /// システムが自動作成（Documents/sessions/<id> など）
    case automatic

    /// ユーザーが明示的に指定
    case userSpecified(path: String)
}
