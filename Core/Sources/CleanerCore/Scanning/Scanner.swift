import Foundation

/// A read-only scanner for one category (or family of related paths).
///
/// Contract:
/// - MUST NOT create, modify, or delete anything on disk.
/// - MUST NOT follow directory symlinks when walking (walkers use
///   `FileManager.DirectoryEnumerationOptions` without `.followsSymlinks` and skip
///   symlinked entries explicitly).
/// - SHOULD return an empty array (not throw) for missing optional paths.
/// - SHOULD append a `ScanIssue` for permission failures rather than aborting.
/// - MUST only return items located under the roots it declares — the `ScanEngine`
///   filters every result through the rules engine afterwards (defense in depth).
public protocol Scanner: Sendable {
    /// Stable identifier for logging/diagnostics.
    var name: String { get }
    /// Categories this scanner can produce.
    var supportedCategories: Set<JunkCategory> { get }
    /// Run the scan. Called concurrently with other scanners.
    func scan(_ context: ScanContext) async -> ScannerResult
}

/// Results of a single scanner run.
public struct ScannerResult: Sendable {
    public var items: [JunkItem]
    public var issues: [ScanIssue]
    /// Category order for deduplication: when the same path is returned by several
    /// scanners, the one with the *lowest* priority value wins (more specific scanners
    /// get lower values than the generic `~/Library/Caches` sweep).
    public var categorySpecificity: [JunkCategory: Int]

    public init(
        items: [JunkItem] = [],
        issues: [ScanIssue] = [],
        categorySpecificity: [JunkCategory: Int] = [:]
    ) {
        self.items = items
        self.issues = issues
        self.categorySpecificity = categorySpecificity
    }
}

// MARK: - Shared walking helpers

enum ScanSupport {
    /// Recursive byte total (allocated) and per-entry metadata for direct children of `root`.
    /// Does not follow symlinks; a symlinked entry contributes its own size only (0 bytes
    /// as reported by resource values for the link itself) and is not traversed.
    static func directoryTotalSize(at url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .totalFileAllocatedSizeKey])
            if values?.isSymbolicLink == true {
                // Never traverse through the link.
                enumerator.skipDescendants()
                continue
            }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Size of a single entry: files contribute their allocated size, directories the
    /// recursive total, symlinks contribute zero and are never traversed.
    static func size(of url: URL, fileManager: FileManager) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey])
        if values?.isSymbolicLink == true { return 0 }
        if values?.isDirectory == true {
            return directoryTotalSize(at: url, fileManager: fileManager)
        }
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    /// Non-recursive size of a file (used by the duplicate finder).
    static func fileSize(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true, values?.isRegularFile == true else { return nil }
        return Int64(values?.fileSize ?? 0)
    }

    /// Lists direct children of a directory, recording permission problems as issues.
    static func contents(
        of directory: URL,
        category: JunkCategory,
        fileManager: FileManager
    ) -> (urls: [URL], issues: [ScanIssue]) {
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: []
            )
            return (urls, [])
        } catch let error as NSError {
            let reason: ScanIssue.Reason
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                reason = .permissionDenied
            } else if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                reason = .notFound
            } else if (error.domain == NSPOSIXErrorDomain && (error.code == Int(EACCES) || error.code == Int(EPERM))) {
                reason = .permissionDenied
            } else {
                reason = .unreadable
            }
            // Missing optional paths are normal; don't spam the issue list.
            if reason == .notFound { return ([], []) }
            return ([], [ScanIssue(path: directory, category: category, reason: reason)])
        }
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
