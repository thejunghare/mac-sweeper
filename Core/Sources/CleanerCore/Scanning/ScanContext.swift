import Foundation

/// Read-only scanning context handed to every scanner.
///
/// A scanner must never mutate the filesystem. It should honor cancellation cooperatively
/// (check `Task.isCancelled` in long loops) and report unreadable paths as `ScanIssue`
/// instead of throwing on first failure.
public struct ScanContext: Sendable {
    /// The user's home directory. Tests inject a fixture directory instead.
    public let homeDirectory: URL
    public let fileManager: FileManager
    public let configuration: ScanConfiguration
    /// Optional additional roots to scan (unused in v1; reserved for user-picked folders).
    public let additionalRoots: [URL]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        configuration: ScanConfiguration = ScanConfiguration(),
        additionalRoots: [URL] = []
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.configuration = configuration
        self.additionalRoots = additionalRoots
    }

    public func url(_ relativePath: String, in base: URL? = nil) -> URL {
        (base ?? homeDirectory).appendingPathComponent(relativePath)
    }

    public func library(_ relativePath: String) -> URL {
        url("Library/" + relativePath)
    }
}

/// Tunables for scanning. Defaults are chosen for v1 (§4) and exposed in Settings later.
public struct ScanConfiguration: Sendable {
    /// Categories to include. Empty = all.
    public var enabledCategories: Set<JunkCategory>
    /// Minimum size for the large-files scanner.
    public var largeFileMinimumSize: Int64
    /// Maximum results from the large-files scanner (keeps the scan bounded).
    public var largeFileResultLimit: Int
    /// Maximum recursion depth for the large-files walk below the home directory.
    public var largeFileMaximumDepth: Int
    /// Whether to descend into `~/Library` during the large-files walk (off by default —
    /// Library content is covered by dedicated scanners).
    public var largeFilesIncludeLibrary: Bool
    /// Minimum group size (bytes) before the duplicate scanner considers a file.
    public var duplicateMinimumSize: Int64
    /// Directories scanned by the duplicate finder.
    public var duplicateRoots: [String]
    /// Folders the user explicitly excluded (paths under home).
    public var excludedPaths: [String]

    public init(
        enabledCategories: Set<JunkCategory> = Set(JunkCategory.allCases),
        largeFileMinimumSize: Int64 = 500 * 1024 * 1024,
        largeFileResultLimit: Int = 500,
        largeFileMaximumDepth: Int = 8,
        largeFilesIncludeLibrary: Bool = false,
        duplicateMinimumSize: Int64 = 1024 * 1024,
        duplicateRoots: [String] = ["Downloads", "Documents", "Desktop", "Pictures"],
        excludedPaths: [String] = []
    ) {
        self.enabledCategories = enabledCategories
        self.largeFileMinimumSize = largeFileMinimumSize
        self.largeFileResultLimit = largeFileResultLimit
        self.largeFileMaximumDepth = largeFileMaximumDepth
        self.largeFilesIncludeLibrary = largeFilesIncludeLibrary
        self.duplicateMinimumSize = duplicateMinimumSize
        self.duplicateRoots = duplicateRoots
        self.excludedPaths = excludedPaths.map { ($0 as NSString).standardizingPath }
    }

    public func isExcluded(path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        return excludedPaths.contains { standardized == $0 || standardized.hasPrefix($0 + "/") }
    }
}
