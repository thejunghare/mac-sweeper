import Foundation

/// Walks the home folder, finds the single most deeply nested regular file, tells the user
/// whether Broom may delete it, and suggests other files that are safe to remove.
///
/// The deepest-file part is the in-app equivalent of the Terminal one-liner
/// `find ~ -type f | awk -F/ '{print NF, $0}' | sort -n | tail -1`, with the same
/// read-only guarantees as every scanner:
/// - never creates, modifies or deletes anything;
/// - never follows symlinks (linked directories are not traversed, linked files are skipped);
/// - unreadable directories are counted and skipped, never fatal;
/// - cancellable between entries.
///
/// Suggestions are files inside a junk location (caches, logs, Xcode/Homebrew data, …) that
/// pass every delete-time gate. Deleting them still goes through `SafeDeleter`, which
/// re-validates each one — a suggestion is never trusted on its own.
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

    /// A file Broom suggests removing: in a junk location, low or medium risk, and cleared
    /// by the rules engine, the symlink guard and the filesystem's permission check.
    public struct Suggestion: Sendable, Hashable, Identifiable {
        public let item: JunkItem
        /// Path components below the searched root.
        public let depth: Int

        public var id: String { item.id }
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
        /// Safe-to-remove files, deepest first (bounded by `suggestionLimit`).
        public let suggestions: [Suggestion]

        public var displayPath: String { homeRelativePath(path) }
    }

    private let rules: RulesEngine
    private let fileManager: FileManager
    private let suggestionLimit: Int
    private let pathGuard = SymlinkGuard()

    public init(
        rules: RulesEngine = RulesEngine(),
        fileManager: FileManager = .default,
        suggestionLimit: Int = 200
    ) {
        self.rules = rules
        self.fileManager = fileManager
        self.suggestionLimit = suggestionLimit
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
        var candidates: [(url: URL, depth: Int)] = []

        for case let url as URL in enumerator {
            if Task.isCancelled { break }

            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }

            examined += 1
            if examined % 2_000 == 0 { progress?(examined) }

            let depth = enumerator.level

            // Cheap, string-only location check while walking; the full delete-time gates
            // run later on the bounded shortlist only.
            if case .junk = classify(url.standardizedFileURL.path) {
                candidates.append((url, depth))
                if candidates.count > suggestionLimit * 4 {
                    candidates = shortlist(candidates)
                }
            }

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
            unreadableDirectories: unreadable.value,
            suggestions: makeSuggestions(from: shortlist(candidates))
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

    // MARK: - Suggestions

    /// Deepest first, then alphabetical, capped at `suggestionLimit`.
    private func shortlist(_ candidates: [(url: URL, depth: Int)]) -> [(url: URL, depth: Int)] {
        let sorted = candidates.sorted {
            $0.depth != $1.depth ? $0.depth > $1.depth : $0.url.path < $1.url.path
        }
        return Array(sorted.prefix(suggestionLimit))
    }

    private func makeSuggestions(from candidates: [(url: URL, depth: Int)]) -> [Suggestion] {
        candidates.compactMap { candidate in
            let url = candidate.url.standardizedFileURL
            // High-risk data (device backups) is never offered for one-click removal.
            guard case let .junk(category, root) = classify(url.path),
                  category.riskLevel < .high else { return nil }
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
            )
            let item = JunkItem(
                path: url,
                size: Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0),
                category: category,
                riskLevel: category.riskLevel,
                modificationDate: values?.contentModificationDate,
                root: root
            )
            guard deleteGateFailure(for: item) == nil else { return nil }
            return Suggestion(item: item, depth: candidate.depth)
        }
    }

    // MARK: - Deletion verdict

    private enum Location {
        case junk(JunkCategory, root: URL)
        case refused(String)
    }

    /// Where a path sits, judged by location alone (pure string checks, no disk access).
    private func classify(_ path: String) -> Location {
        if let denied = rules.hardDenylist.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .refused("System location (\(denied)) — on Broom's hard denylist, never deleted.")
        }
        if let protected = rules.protectedHomeRoots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            let name = (protected as NSString).lastPathComponent
            return .refused("Inside your \(name) folder — Broom never deletes your own documents.")
        }
        if rules.allowedRoots(for: .trash).contains(where: { path.hasPrefix($0.standardizedFileURL.path + "/") }) {
            return .refused("Already in the Trash — empty the Trash in Finder to remove it permanently.")
        }

        guard let match = rules.junkLocation(for: path) else {
            return .refused(
                "Not in a junk location Broom cleans — review it and delete it yourself " +
                "in Finder if you no longer need it."
            )
        }
        return .junk(match.category, root: match.root)
    }

    /// The same gates `SafeDeleter` applies (rules engine + symlink guard) plus the
    /// filesystem's own permission check. Returns `nil` when all pass.
    private func deleteGateFailure(for item: JunkItem) -> String? {
        guard rules.mayDelete(item) else {
            return "Rejected by Broom's safety rules."
        }
        if let rejection = pathGuard.rejectionReason(for: item, fileManager: fileManager) {
            return "Path safety check failed (\(rejection))."
        }
        guard fileManager.isDeletableFile(atPath: item.path.path) else {
            return "macOS permissions don't allow removing it (owned by another user or protected)."
        }
        return nil
    }

    /// Whether Broom may delete `fileURL`, with the reason. Never deletes anything.
    public func verdict(for fileURL: URL) -> Verdict {
        let url = fileURL.standardizedFileURL
        switch classify(url.path) {
        case .refused(let reason):
            return .no(reason)
        case let .junk(category, root):
            let item = JunkItem(path: url, size: 0, category: category, riskLevel: category.riskLevel, root: root)
            if let failure = deleteGateFailure(for: item) {
                return .no(failure)
            }
            return Verdict(
                canDelete: true,
                category: category,
                riskLevel: category.riskLevel,
                reason: "Inside \(category.displayName) — Broom can move it to the Trash."
            )
        }
    }
}

/// Mutable counter shared with the enumerator's error handler.
private final class Counter: @unchecked Sendable {
    var value = 0
}
