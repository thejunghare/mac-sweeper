import AppKit
import CleanerCore
import Foundation

/// State for the Storage screen: per-section contents, direct Move-to-Trash and Undo.
///
/// "Safe to delete" items go to the Trash on one click; "Check first" items (your files,
/// apps) ask once before moving; "Can't delete" items can only be revealed in Finder.
@MainActor
final class StorageViewModel: ObservableObject {
    @Published private(set) var reports: [StorageSection: StorageSectionReport] = [:]
    @Published private(set) var isAnalyzing = false
    @Published private(set) var diskUsage: DiskUsage? = DiskUsage.current()
    @Published var selectedSection: StorageSection? = .applications
    @Published private(set) var isDeleting = false
    @Published private(set) var message: String?
    /// "Check first" items waiting for the user's one confirmation.
    @Published var pendingConfirmation: [StorageEntry] = []

    private let analyzer = StorageAnalyzer()
    private var analyzeTask: Task<Void, Never>?
    private var lastDelete: (cleanID: UUID, entries: [StorageEntry])?

    var canUndo: Bool { lastDelete != nil && !isDeleting }

    // MARK: Analysis

    func analyze() {
        analyzeTask?.cancel()
        reports = [:]
        message = nil
        lastDelete = nil
        isAnalyzing = true
        diskUsage = DiskUsage.current()

        let analyzer = self.analyzer
        analyzeTask = Task {
            let all = await analyzer.analyzeAll { [weak self] report in
                Task { @MainActor [weak self] in
                    self?.reports[report.section] = report
                }
            }
            guard !Task.isCancelled else { return }
            for report in all { self.reports[report.section] = report }
            self.isAnalyzing = false
        }
    }

    func cancel() {
        analyzeTask?.cancel()
        analyzeTask = nil
        isAnalyzing = false
    }

    // MARK: Deletion

    /// Safe items are trashed immediately; anything flagged "Check first" asks once.
    func requestDelete(_ entries: [StorageEntry]) {
        let deletable = entries.filter { $0.flag.isDeletable }
        guard !deletable.isEmpty else { return }
        if deletable.contains(where: { $0.flag == .checkFirst }) {
            pendingConfirmation = deletable
        } else {
            Task { await delete(deletable) }
        }
    }

    func confirmPendingDelete() {
        let entries = pendingConfirmation
        pendingConfirmation = []
        Task { await delete(entries) }
    }

    private func delete(_ entries: [StorageEntry]) async {
        guard !entries.isEmpty, !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        let undoLog: UndoLog
        do {
            undoLog = try UndoLog()
        } catch {
            message = "Could not open the undo log: \(error.localizedDescription)"
            return
        }
        let outcome = await StorageDeleter(analyzer: analyzer, undoLog: undoLog).trash(entries)

        let trashedIDs = Set(outcome.trashed.map(\.id))
        for (section, report) in reports {
            reports[section] = StorageSectionReport(
                section: section,
                entries: report.entries.filter { !trashedIDs.contains($0.id) }
            )
        }
        lastDelete = outcome.trashed.isEmpty ? nil : (outcome.cleanID, outcome.trashed)
        diskUsage = DiskUsage.current()

        var text = "Moved \(outcome.trashed.count) item\(outcome.trashed.count == 1 ? "" : "s") " +
            "(\(ByteFormat.string(outcome.freedBytes))) to the Trash."
        if let failure = outcome.failures.first {
            text += " \(outcome.failures.count) not moved: \(failure.reason)"
        }
        message = text
    }

    func undoLastDelete() async {
        guard let last = lastDelete else { return }
        do {
            let log = try UndoLog()
            let entries = await log.all().filter { $0.cleanID == last.cleanID }
            let result = UndoRestorer().restore(entries)
            let restoredPaths = Set(result.restored.map(\.originalPath))

            for entry in last.entries where restoredPaths.contains(entry.id) {
                let current = reports[entry.section]?.entries ?? []
                reports[entry.section] = StorageSectionReport(
                    section: entry.section,
                    entries: (current + [entry]).sorted { $0.size > $1.size }
                )
            }
            lastDelete = nil
            diskUsage = DiskUsage.current()

            message = "Restored \(result.restored.count) item\(result.restored.count == 1 ? "" : "s")."
            if let skipped = result.skipped.first {
                message? += " \(result.skipped.count) could not be restored: \(skipped.reason)"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Finder

    func reveal(_ entry: StorageEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.path])
    }

    func openTrash() {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        NSWorkspace.shared.open(trash)
    }
}
