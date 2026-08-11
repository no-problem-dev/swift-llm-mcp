import Foundation

// MARK: - PathBoundary

/// The directories a tool kit lets the model reach, and the check that decides whether a path
/// is one of them.
///
/// ``FileSystemToolKit`` and ``ScriptBridge`` both hold one rather than each carrying its own
/// comparison, because two copies of a containment rule drift and only one of them gets fixed.
///
/// Containment is by path component, so `/data` does not admit `/database`, and every path is
/// canonicalized — symlinks resolved — before it is judged, so a link inside an allowed
/// directory cannot lead out of it.
internal struct PathBoundary: Sendable {
    /// The allowed roots in canonical form. `nil` imposes no boundary.
    let allowedRoots: [String]?

    /// Expands a leading `~` in each root and canonicalizes it.
    ///
    /// Canonicalizing the roots is what lets a caller name one through a symlink: on macOS
    /// `/tmp` and the temporary directory are both links, so an uncanonicalized root would
    /// never match the real paths its own files resolve to.
    init(allowedPaths: [String]?) {
        self.allowedRoots = allowedPaths?.map { path in
            Self.canonical(NSString(string: path).expandingTildeInPath)
        }
    }

    /// Resolves `path` and returns its canonical form, provided it lies inside a root.
    ///
    /// A path not starting with `/` resolves against `workingDirectory`.
    ///
    /// - Throws: ``PathOutsideBoundary`` when the resolved path is neither a root nor a
    ///   descendant of one.
    func resolve(_ path: String, workingDirectory: String) throws(PathOutsideBoundary) -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath

        var absolutePath: String
        if expandedPath.hasPrefix("/") {
            absolutePath = expandedPath
        } else {
            absolutePath = (workingDirectory as NSString).appendingPathComponent(expandedPath)
        }
        if !absolutePath.hasPrefix("/") {
            absolutePath = (FileManager.default.currentDirectoryPath as NSString)
                .appendingPathComponent(absolutePath)
        }

        let canonicalPath = Self.canonical(absolutePath)

        // No list means no boundary.
        guard let allowedRoots else { return canonicalPath }

        let isAllowed = allowedRoots.contains { root in
            Self.isWithin(canonicalPath, root: root)
        }

        guard isAllowed else {
            throw PathOutsideBoundary(path: canonicalPath, allowedRoots: allowedRoots)
        }

        return canonicalPath
    }

    // MARK: - Containment

    /// Whether `path` is `root` itself or something below it.
    ///
    /// The separator is part of the comparison, which is the whole difference between this and
    /// a string prefix: `/database` shares a prefix with `/data` but not a component boundary.
    /// Both arguments must already be canonical.
    static func isWithin(_ path: String, root: String) -> Bool {
        if path == root { return true }
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(rootPrefix)
    }

    // MARK: - Canonicalization

    /// The path with `.` and `..` applied and every symlink resolved, whether or not it exists.
    ///
    /// Resolution walks down from the root one component at a time, so what has been resolved
    /// so far is always symlink-free. That is what makes `..` exact: collapsing `..` first, as
    /// a purely lexical standardization does, would let `link/../secret` name a sibling of the
    /// link rather than a sibling of the directory the link actually points at.
    ///
    /// Components below the deepest existing one cannot be resolved further and are appended
    /// as written, so a file that does not exist yet is judged at the place it would land.
    static func canonical(_ path: String) -> String {
        var resolved = "/"

        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                resolved = (resolved as NSString).deletingLastPathComponent
                if resolved.isEmpty { resolved = "/" }
            default:
                let candidate = (resolved as NSString).appendingPathComponent(String(component))
                resolved = resolvedExistingPath(candidate) ?? candidate
            }
        }

        return resolved
    }

    /// The kernel's answer for a path that exists, or `nil` for one that does not.
    private static func resolvedExistingPath(_ path: String) -> String? {
        guard let buffer = Foundation.realpath(path, nil) else { return nil }
        defer { free(buffer) }
        return String(cString: buffer)
    }
}

// MARK: - PathOutsideBoundary

/// A path that resolved to somewhere no allowed root contains.
///
/// Carries the canonical path rather than the one the model wrote, because after symlink
/// resolution those differ and the canonical one is where the access would have landed.
internal struct PathOutsideBoundary: Error {
    let path: String
    let allowedRoots: [String]
}
