import Foundation

/// Finds the single most deeply nested regular file under a root and tells the user
/// whether Broom may delete it.
///
/// This is the in-app equivalent of the Terminal one-liner
/// `find ~ -type f | awk -F/ '{print NF, $0}' | sort -n | tail -1`, with the same
/// read-only guarantees as every scanner:
/// - never creates, modifies or deletes anything;
/// - never follows symlinks (linked directories are not traversed, linked files are skipped);
/// - unreadable directories are counted and skipped, never fatal;
/// - cancellable between entries.
///
/// The deepest file is *informational*: the verdict explains whether it lives in a location
/// Broom cleans, but the finder never hands anything to the deletion engine.
public struct DeepestFileFinder: Sendable {

    /// Whether Broom could move a given file to the Trash, and why (or why not).
    public struct Verdict: Sendable, Equatable {
        public let canDelete: Bool
        /// The deletable category the file falls under, when there is one.
        public let category: JunkCategory?
        public let riskLevel: RiskLevel?
        /// One factual sentence shown next to the flag.
        public let reason: String

        static func no(_ reason: String) -> Verdict {
            Verdict(canDelete: false, category: nil, riskLevel: nil, reason: reason)
        }
    }

    public struct Result: Sendable, Equatable {
        public let path: URL
        /// Path components below the searched root (a direct child has depth 1).
        public let depth: Int
        public let size: Int64
        public let modificationDate: Date?
        public let verdict: Verdict
        /// Other files sharing the same maximum depth (0 = this one is the only deepest).
        public let otherFilesAtSameDepth: Int
        public let filesExamined: Int
        /// Directories that could not be read (usually missing Full Disk Access).
        public let unreadableDirectories: Int

        public var displayPath: String { homeRelativePath(path) }
    }

    private let rules: RulesEngine
    private let fileManager: FileManager
    private let pathGuard = SymlinkGuard()

    public init(rules: RulesEngine = RulesEngine(), fileManager: FileManager = .default) {
        self.rules = rules
        self.fileManager = fileManager
    }

    /// Walks `root` (default: the rules engine's home directory). Returns `nil` when no
    /// regular file was found or the walk was cancelled before finding one.
    ///
    /// Synchronous by nature (directory enumeration); call it off the main thread.
    /// `progress` receives the running count of files examined, throttled.
    public func find(
        in root: URL? = nil,
        progress: ((Int) -> Void)? = nil
    ) -> Result? {
        let root = (root ?? rules.homeDirectory).standardizedFileURL
        let unreadable = Counter()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [], // no .followsSymlinks — never traverse links
            errorHandler: { _, _ in
                unreadable.value += 1
                return true
            }
        ) else { return nil }

        var deepest: (url: URL, depth: Int)?
        var ties = 0
        var examined = 0

        for case let url as URL in enumerator {
            if Task.isCancelled { break }

            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }

            examined += 1
            if examined % 2_000 == 0 { progress?(examined) }

            let depth = enumerator.level
            if let current = deepest {
                if depth < current.depth { continue }
                if depth == current.depth {
                    ties += 1
                    // Deterministic tie-break: alphabetically first path wins.
                    if url.path >= current.url.path { continue }
                } else {
                    ties = 0
                }
            }
            deepest = (url, depth)
        }
        progress?(examined)

        guard let best = deepest else { return nil }
        let values = try? best.url.resourceValues(
            forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
        )
        return Result(
            path: best.url.standardizedFileURL,
            depth: best.depth,
            size: Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0),
            modificationDate: values?.contentModificationDate,
            verdict: verdict(for: best.url),
            otherFilesAtSameDepth: ties,
            filesExamined: examined,
            unreadableDirectories: unreadable.value
        )
    }

    /// Async wrapper that runs the walk off the caller's actor.
    public func findDeepestFile(
        in root: URL? = nil,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async -> Result? {
        let finder = self
        let task = Task.detached(priority: .userInitiated) {
            finder.find(in: root, progress: progress)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Deletion verdict

    /// Categories a loose file can be attributed to by location alone. Excluded:
    /// - informational categories (never deleted in-app);
    /// - Trash (the deleter never purges it — the user empties the Trash);
    /// - leftover app files: being under `~/Library/Application Support` is not enough,
    ///   the owning app must be uninstalled, which only `LeftoverAppFilesScanner` can tell.
    static let locationCategories: [JunkCategory] = JunkCategory.allCases.filter {
        $0.isDeletable && $0 != .trash && $0 != .leftoverAppFiles
    }

    /// Applies the same gates as `SafeDeleter` (rules engine + symlink guard) plus the
    /// filesystem's own permission check, without deleting anything.
    public func verdict(for fileURL: URL) -> Verdict {
        let url = fileURL.standardizedFileURL
        let path = url.path

        if let denied = rules.hardDenylist.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .no("System location (\(denied)) — on Broom's hard denylist, never deleted.")
        }
        if let protected = rules.protectedHomeRoots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            let name = (protected as NSString).lastPathComponent
            return .no("Inside your \(name) folder — Broom never deletes your own documents.")
        }
        if rules.allowedRoots(for: .trash).contains(where: { path.hasPrefix($0.standardizedFileURL.path + "/") }) {
            return .no("Already in the Trash — empty the Trash in Finder to remove it permanently.")
        }

        // Most specific matching root wins (e.g. Homebrew cache beats the generic Caches sweep).
        var match: (category: JunkCategory, root: URL)?
        for category in Self.locationCategories {
            for root in rules.allowedRoots(for: category) {
                let rootPath = root.standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { continue }
                if let current = match, current.root.path.count >= rootPath.count { continue }
                match = (category, root.standardizedFileURL)
            }
        }
        guard let match else {
            return .no(
                "Not in a junk location Broom cleans — review it and delete it yourself " +
                "in Finder if you no longer need it."
            )
        }

        let item = JunkItem(
            path: url,
            size: 0,
            category: match.category,
            riskLevel: match.category.riskLevel,
            root: match.root
        )
        guard rules.mayDelete(item) else {
            return .no("Rejected by Broom's safety rules.")
        }
        if let rejection = pathGuard.rejectionReason(for: item, fileManager: fileManager) {
            return .no("Path safety check failed (\(rejection)).")
        }
        guard fileManager.isDeletableFile(atPath: path) else {
            return .no("macOS permissions don't allow removing it (owned by another user or protected).")
        }
        return Verdict(
            canDelete: true,
            category: match.category,
            riskLevel: match.category.riskLevel,
            reason: "Inside \(match.category.displayName) — Broom can move it to the Trash."
        )
    }
}

/// Mutable counter shared with the enumerator's error handler.
private final class Counter: @unchecked Sendable {
    var value = 0
}
