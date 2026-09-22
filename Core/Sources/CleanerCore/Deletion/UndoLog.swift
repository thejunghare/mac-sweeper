import Foundation

/// One recorded deletion, enabling in-app "Undo last clean" (§6).
public struct UndoEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { uuid }
    public let uuid: UUID
    /// Batch identifier — all items deleted in one "Clean" action share it.
    public let cleanID: UUID
    public let originalPath: String
    /// Where the item sits in the Trash now (nil if `trashed` is false).
    public let trashedURL: String?
    public let timestamp: Date
    public let category: JunkCategory
    public let size: Int64
    /// True when the "deletion" was trashing an item that was *already* in the Trash
    /// (i.e. Finder-level permanent deletion is NOT performed — such items are skipped;
    /// this flag exists so the UI can explain why Trash items can't be undone).
    public let trashed: Bool

    public init(
        cleanID: UUID,
        originalPath: String,
        trashedURL: String?,
        timestamp: Date = Date(),
        category: JunkCategory,
        size: Int64,
        trashed: Bool
    ) {
        self.uuid = UUID()
        self.cleanID = cleanID
        self.originalPath = originalPath
        self.trashedURL = trashedURL
        self.timestamp = timestamp
        self.category = category
        self.size = size
        self.trashed = trashed
    }
}

/// Append-only-ish on-disk log of deletions (§6 step 4), stored as JSON in
/// Application Support. Thread-safe via actor isolation; writes are atomic.
public actor UndoLog {
    public let fileURL: URL
    private var entries: [UndoEntry]
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: injectable for tests; defaults to
    ///   `~/Library/Application Support/Broom`.
    public init(directory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let dir = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Broom", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("undo_log.json")

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if fileManager.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let loaded = try? decoder.decode([UndoEntry].self, from: data) {
            self.entries = loaded
        } else {
            self.entries = []
        }
    }

    public func all() -> [UndoEntry] { entries }

    public func lastCleanID() -> UUID? { entries.last?.cleanID }

    /// Entries belonging to the most recent clean batch.
    public func entriesForLastClean() -> [UndoEntry] {
        guard let lastID = entries.last?.cleanID else { return [] }
        return entries.filter { $0.cleanID == lastID }
    }

    public func append(_ entry: UndoEntry) throws {
        entries.append(entry)
        try persist()
    }

    /// Prune entries older than `maxAge` (default: keep one month of history).
    public func prune(olderThan maxAge: TimeInterval = 30 * 24 * 60 * 60) throws {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let before = entries.count
        entries.removeAll { $0.timestamp < cutoff }
        if entries.count != before { try persist() }
    }

    private func persist() throws {
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: [.atomic])
    }
}
