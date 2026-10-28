import Foundation

/// Deletes items the user picked in the Storage screen — the in-app equivalent of
/// Finder's "Move to Trash".
///
/// Guarantees (same spirit as `SafeDeleter`, §5.2):
/// - **Trash, never unlink/rm** — everything stays recoverable until the user empties it;
/// - **Re-checked at delete time** — the flag is recomputed from disk right now (a stale
///   "Can delete" from the listing is never trusted) and `SymlinkGuard` verifies the item
///   is still inside its folder;
/// - **Recorded** in the undo log, so the screen can offer Undo.
public actor StorageDeleter {
    public struct Outcome: Sendable {
        public let cleanID: UUID
        public var trashed: [StorageEntry] = []
        public var failures: [(entry: StorageEntry, reason: String)] = []
        public var freedBytes: Int64 { trashed.reduce(0) { $0 + $1.size } }

        public init(cleanID: UUID) {
            self.cleanID = cleanID
        }
    }

    private let analyzer: StorageAnalyzer
    private let undoLog: UndoLog
    private let fileManager: FileManager
    private let pathGuard = SymlinkGuard()
    private let logger: CoreLogging

    public init(
        analyzer: StorageAnalyzer,
        undoLog: UndoLog,
        fileManager: FileManager = .default,
        logger: CoreLogging = .shared
    ) {
        self.analyzer = analyzer
        self.undoLog = undoLog
        self.fileManager = fileManager
        self.logger = logger
    }

    @discardableResult
    public func trash(_ entries: [StorageEntry]) async -> Outcome {
        var outcome = Outcome(cleanID: UUID())

        for entry in entries {
            if Task.isCancelled { break }

            // 1. Recompute the flag now.
            let current = analyzer.flag(for: entry.path)
            guard current.flag.isDeletable else {
                outcome.failures.append((entry, current.note))
                continue
            }

            // 2. Still inside its folder (symlink / TOCTOU check). UndoEntry needs a
            //    category: user files outside junk locations are recorded as large files —
            //    metadata only, it doesn't change how the item is handled.
            let category = analyzer.rules.junkLocation(for: entry.path.path)?.category ?? .largeFiles
            let probe = JunkItem(
                path: entry.path,
                size: entry.size,
                category: category,
                riskLevel: category.riskLevel,
                root: entry.root
            )
            guard entry.path.path != entry.root.path else {
                outcome.failures.append((entry, "Folder macOS needs"))
                continue
            }
            if let rejection = pathGuard.rejectionReason(for: probe, fileManager: fileManager) {
                outcome.failures.append((entry, "Path safety check failed: \(rejection)"))
                continue
            }

            // 3. Move to Trash.
            do {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: entry.path, resultingItemURL: &resultingURL)
                outcome.trashed.append(entry)
                try await undoLog.append(
                    UndoEntry(
                        cleanID: outcome.cleanID,
                        originalPath: entry.path.path,
                        trashedURL: (resultingURL as URL?)?.path,
                        category: category,
                        size: entry.size,
                        trashed: true
                    )
                )
                logger.info("Trashed \(entry.path.path)")
            } catch {
                let reason = (error as NSError).localizedDescription
                outcome.failures.append((entry, reason))
                logger.warning("Failed to trash \(entry.path.path): \(reason)")
            }
        }
        return outcome
    }
}
