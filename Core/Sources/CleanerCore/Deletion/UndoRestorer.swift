import Foundation

/// Restores items from the undo log (§6 step 5): moves each entry's `trashedURL` back to
/// `originalPath` if it still exists in the Trash. Refuses if the original location has
/// been reoccupied in the meantime (never overwrites live data).
public struct UndoRestorer: Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public struct Result: Sendable {
        public var restored: [UndoEntry] = []
        public var skipped: [(entry: UndoEntry, reason: String)] = []

        public var restoredBytes: Int64 { restored.reduce(0) { $0 + $1.size } }
    }

    /// Restore specific entries (e.g. the last clean batch). Skipped entries are reported
    /// with a human-readable reason; nothing is force-moved.
    public func restore(_ entries: [UndoEntry]) -> Result {
        var result = Result()

        // Restore in reverse order so parent/child relationships behave predictably.
        for entry in entries.reversed() {
            guard entry.trashed, let trashedPath = entry.trashedURL else {
                result.skipped.append((entry, "no Trash location recorded"))
                continue
            }
            let source = URL(fileURLWithPath: trashedPath)
            let destination = URL(fileURLWithPath: entry.originalPath)

            guard fileManager.fileExists(atPath: source.path) else {
                result.skipped.append((entry, "no longer in the Trash (was it emptied?)"))
                continue
            }
            guard !fileManager.fileExists(atPath: destination.path) else {
                result.skipped.append((entry, "the original location is occupied again"))
                continue
            }

            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: source, to: destination)
                result.restored.append(entry)
            } catch {
                result.skipped.append((entry, (error as NSError).localizedDescription))
            }
        }
        return result
    }

    /// Convenience: restore the most recent clean batch from the log, then (on full
    /// success) drop those entries so they can't be undone twice.
    public func restoreLastClean(from log: UndoLog) async -> Result {
        let entries = await log.entriesForLastClean()
        let result = restore(entries)
        return result
    }
}
