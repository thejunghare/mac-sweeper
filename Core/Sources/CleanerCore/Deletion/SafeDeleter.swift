import Foundation

/// Safe deletion engine (§5.2, §6 step 4).
///
/// Guarantees:
/// - **Trash, never unlink/rm**: every delete goes through
///   `FileManager.trashItem(at:resultingItemURL:)`, so everything is recoverable from the
///   Trash until the user empties it themselves (we never auto-empty).
/// - **Re-validated at delete time**: rules engine (`mayDelete`) + `SymlinkGuard`
///   run immediately before each trash operation — scan-time results are never trusted.
/// - **Cancellable**: checked between items; a cancelled run stops cleanly and reports
///   what already happened.
/// - **Audited**: every success/failure is written to the undo log (§6) and logged locally.
public actor SafeDeleter {
    public struct Progress: Sendable {
        public var completed: Int
        public var total: Int
        public var currentItem: JunkItem?
        public var freedBytes: Int64

        public init(completed: Int, total: Int, currentItem: JunkItem?, freedBytes: Int64) {
            self.completed = completed
            self.total = total
            self.currentItem = currentItem
            self.freedBytes = freedBytes
        }

        public var fractionCompleted: Double {
            total == 0 ? 1 : Double(completed) / Double(total)
        }
    }

    public struct Failure: Sendable {
        public let item: JunkItem
        public let reason: String
    }

    public struct Outcome: Sendable {
        public let cleanID: UUID
        public var trashed: [(item: JunkItem, trashURL: URL?)] = []
        public var failures: [Failure] = []
        public var freedBytes: Int64 { trashed.reduce(0) { $0 + $1.item.size } }
        public var wasCancelled = false

        public init(cleanID: UUID) {
            self.cleanID = cleanID
        }
    }

    private let fileManager: FileManager
    private let rules: RulesEngine
    private let pathGuard = SymlinkGuard()
    private let undoLog: UndoLog
    private let logger: CoreLogging

    public init(
        rules: RulesEngine,
        undoLog: UndoLog,
        fileManager: FileManager = .default,
        logger: CoreLogging = .shared
    ) {
        self.rules = rules
        self.undoLog = undoLog
        self.fileManager = fileManager
        self.logger = logger
    }

    /// Trash the given items sequentially with progress. Caller decides confirmation
    /// tiers (§5.2) before invoking this — the engine refuses informational categories
    /// and anything failing validation regardless.
    @discardableResult
    public func trash(
        _ items: [JunkItem],
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async -> Outcome {
        let cleanID = UUID()
        var outcome = Outcome(cleanID: cleanID)
        let total = items.count

        for (index, item) in items.enumerated() {
            if Task.isCancelled {
                outcome.wasCancelled = true
                logger.info("Clean cancelled after \(index)/\(total) items")
                break
            }

            // 1. Re-validate (never trust scan-time results).
            guard rules.mayDelete(item) else {
                outcome.failures.append(Failure(item: item, reason: "rejected by rules engine"))
                progress?(Progress(completed: index + 1, total: total, currentItem: item, freedBytes: outcome.freedBytes))
                continue
            }
            // 2. Re-verify on-disk location (symlink/TOCTOU).
            if let rejection = pathGuard.rejectionReason(for: item, fileManager: fileManager) {
                outcome.failures.append(Failure(item: item, reason: "path safety check failed: \(rejection)"))
                progress?(Progress(completed: index + 1, total: total, currentItem: item, freedBytes: outcome.freedBytes))
                continue
            }

            // 3. Items already in the Trash are handled by the user's explicit
            //    "Empty Trash" action — never auto-purge (§6 step 6).
            if item.category == .trash {
                outcome.failures.append(
                    Failure(item: item, reason: "already in the Trash — use Finder's Empty Trash to purge it")
                )
                progress?(Progress(completed: index + 1, total: total, currentItem: item, freedBytes: outcome.freedBytes))
                continue
            }

            // 4. Trash it.
            do {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: item.path, resultingItemURL: &resultingURL)
                let trashURL = resultingURL as URL?
                outcome.trashed.append((item, trashURL))
                try await undoLog.append(
                    UndoEntry(
                        cleanID: cleanID,
                        originalPath: item.path.path,
                        trashedURL: trashURL?.path,
                        category: item.category,
                        size: item.size,
                        trashed: true
                    )
                )
                logger.info("Trashed \(item.path.path)")
            } catch {
                outcome.failures.append(Failure(item: item, reason: localizedDescription(error)))
                logger.warning("Failed to trash \(item.path.path): \(localizedDescription(error))")
            }

            progress?(Progress(
                completed: index + 1,
                total: total,
                currentItem: item,
                freedBytes: outcome.freedBytes
            ))
        }
        return outcome
    }

    private func localizedDescription(_ error: Error) -> String {
        (error as NSError).localizedDescription
    }
}
