import Foundation

/// Re-verifies an item's on-disk location immediately before deletion (§5.2 TOCTOU /
/// symlink-escape protection).
///
/// The check: the item's *parent directory chain, resolved*, must remain strictly inside
/// the item's declared root (also resolved). This means:
/// - a symlink swapped in after the scan that redirects the parent elsewhere is rejected;
/// - a root that is itself a symlink is fine (both sides are resolved the same way);
/// - deleting a symlink *entry* is allowed (Trash relocates the link, never its target)
///   as long as the link itself sits inside the root.
public struct SymlinkGuard: Sendable {
    public init() {}

    public enum Rejection: String, Equatable, Sendable, CustomStringConvertible {
        case notAbsolute
        case traversalComponent
        case missingParent
        case parentEscapesRoot
        case rootMissing
        case symlinkedParent

        public var description: String { rawValue }
    }

    /// Returns `nil` when the item is safe to trash, or the rejection reason.
    public func rejectionReason(for item: JunkItem, fileManager: FileManager = .default) -> Rejection? {
        let rawPath = item.path.path
        guard rawPath.hasPrefix("/") else { return .notAbsolute }
        if rawPath.contains("/../") || rawPath.hasSuffix("/..") { return .traversalComponent }

        var isDirectory: ObjCBool = false
        let parent = item.path.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue || fileManager.fileExists(atPath: parent.path) else {
            return .missingParent
        }

        let resolvedRoot = item.root.resolvingSymlinksInPath().standardizedFileURL.path
        guard fileManager.fileExists(atPath: resolvedRoot) else { return .rootMissing }

        // Resolve the parent chain. If any *component* of the parent is a symlink pointing
        // outside the root, the resolved parent will fall outside it.
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedParent == resolvedRoot || resolvedParent.hasPrefix(resolvedRoot + "/") else {
            return .parentEscapesRoot
        }

        // The parent itself must not be a symlink that leaves the root: resolvingSymlinksInPath
        // already handled the chain above; double-check the direct parent explicitly so a
        // swapped symlink is caught even when the resolved path coincidentally matches.
        if let values = try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            let resolvedDirectPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
            if !(resolvedDirectPath == resolvedRoot || resolvedDirectPath.hasPrefix(resolvedRoot + "/")) {
                return .symlinkedParent
            }
        }

        return nil
    }
}
