import Foundation

/// A single reclaimable item produced by a scanner, after passing the rules engine.
///
/// Scanners are read-only: constructing a `JunkItem` never touches the file.
public struct JunkItem: Identifiable, Hashable, Sendable {
    /// Absolute path of the item. Never a symlink target — the path as listed on disk.
    public let path: URL
    /// Size in bytes (of this entry; for directories, the recursive total).
    public let size: Int64
    public let category: JunkCategory
    /// Effective risk = max(category default, scanner-declared). Set by `ScanEngine`.
    public let riskLevel: RiskLevel
    /// Last modification date, when available.
    public let modificationDate: Date?
    /// The directory this item must remain inside of; validated again at delete time.
    /// For nested items this is the scanner's configured root, not the parent directory.
    public let root: URL
    /// Optional display detail (e.g. duplicate group info).
    public let detail: String?

    public var id: String { path.path }

    public init(
        path: URL,
        size: Int64,
        category: JunkCategory,
        riskLevel: RiskLevel,
        modificationDate: Date? = nil,
        root: URL,
        detail: String? = nil
    ) {
        self.path = path.standardizedFileURL
        self.size = size
        self.category = category
        self.riskLevel = riskLevel
        self.modificationDate = modificationDate
        self.root = root.standardizedFileURL
        self.detail = detail
    }

    /// Display path relative to the user's home directory where possible.
    public var displayPath: String { homeRelativePath(path) }
}

/// `~`-relative form of an absolute path when it lies inside the user's home directory.
func homeRelativePath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let homePath = home.standardizedFileURL.path
    let pathString = url.path
    if pathString.hasPrefix(homePath + "/") {
        return "~" + String(pathString.dropFirst(homePath.count))
    }
    return pathString
}

/// A non-fatal scanning problem (permission denied, vanished file, ...).surfaced in the UI
/// so failures are explained instead of silently swallowed (§5.1).
public struct ScanIssue: Hashable, Sendable {
    public enum Reason: String, Sendable, Hashable {
        case permissionDenied
        case notFound
        case unreadable
    }

    public let path: URL
    public let category: JunkCategory
    public let reason: Reason

    public init(path: URL, category: JunkCategory, reason: Reason) {
        self.path = path.standardizedFileURL
        self.category = category
        self.reason = reason
    }

    public var explanation: String {
        switch reason {
        case .permissionDenied:
            return "macOS blocked access. Grant Full Disk Access in System Settings → Privacy & Security to include this location."
        case .notFound:
            return "No longer present (may have been moved or deleted since the scan started)."
        case .unreadable:
            return "Could not be read."
        }
    }
}
