import AppKit
import CleanerCore
import Foundation
import SwiftUI

/// Owns all app state: scan lifecycle, item selection, confirmation tiers, cleaning,
/// undo and settings. UI stays declarative; every mutation goes through here.
///
/// Safety invariants enforced here (§5.2 / §6):
/// - only categories with `isDeletable` can ever enter `selection`;
/// - high-risk items are never preselected and require type-to-confirm;
/// - cleaning streams progress and is cancellable between items;
/// - "Undo" is offered for the last clean while its Trash entries still exist.
@MainActor
final class ScanViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning
        case review
        case cleaning
        case finished
    }

    // MARK: Published state

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: ScanReport?
    @Published private(set) var scanProgress: Double = 0
    @Published private(set) var cleanProgress: Double = 0
    @Published private(set) var currentItemName: String = ""
    @Published private(set) var outcome: SafeDeleter.Outcome?
    @Published private(set) var undoResult: UndoRestorer.Result?
    @Published private(set) var lastErrorMessage: String?

    /// Deepest-file lookup (informational; never feeds the deletion engine).
    @Published private(set) var deepestFile: DeepestFileFinder.Result?
    @Published private(set) var isFindingDeepestFile = false
    @Published private(set) var deepestFileFilesExamined = 0
    @Published private(set) var hasSearchedDeepestFile = false

    /// Safe-to-remove files found by the deepest-file walk, with one-click Trash + undo.
    @Published private(set) var suggestions: [DeepestFileFinder.Suggestion] = []
    @Published private(set) var isDeletingSuggestions = false
    @Published private(set) var suggestionMessage: String?
    /// Paths moved to the Trash from the suggestions list (cleared again on undo).
    @Published private(set) var trashedSuggestionPaths: Set<String> = []
    private var lastSuggestionDelete: (cleanID: UUID, items: [DeepestFileFinder.Suggestion])?

    var canUndoSuggestionDelete: Bool { lastSuggestionDelete != nil && !isDeletingSuggestions }

    var suggestionsTotalSize: Int64 { suggestions.reduce(0) { $0 + $1.item.size } }

    /// Paths selected for cleaning.
    @Published var selection: Set<String> = []
    @Published var searchText: String = ""
    @Published var hasFullDiskAccess = FullDiskAccess.hasAccess()

    /// Categories enabled for scanning (persisted in UserDefaults).
    @Published var enabledCategories: Set<JunkCategory> {
        didSet { UserDefaults.standard.set(enabledCategories.map(\.rawValue), forKey: Keys.enabledCategories) }
    }
    /// Minimum size for the large-files scanner, in MB.
    @Published var largeFileMinimumMB: Int {
        didSet { UserDefaults.standard.set(largeFileMinimumMB, forKey: Keys.largeFileMB) }
    }

    // MARK: Derived

    var isBusy: Bool { phase == .scanning || phase == .cleaning }

    /// Items in the current report, filtered by category selection + search text.
    var visibleItems: [JunkItem] {
        guard let report else { return [] }
        var items = report.items
        if !searchText.isEmpty {
            items = items.filter {
                $0.path.path.localizedCaseInsensitiveContains(searchText)
                    || $0.category.displayName.localizedCaseInsensitiveContains(searchText)
                    || ($0.detail?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        return items
    }

    var categoriesInReport: [JunkCategory] {
        guard let report else { return [] }
        return JunkCategory.allCases.filter { category in
            enabledCategories.contains(category) && report.items.contains { $0.category == category }
        }
    }

    func items(in category: JunkCategory) -> [JunkItem] {
        visibleItems.filter { $0.category == category }
    }

    func size(in category: JunkCategory) -> Int64 {
        items(in: category).reduce(0) { $0 + $1.size }
    }

    var selectedItems: [JunkItem] {
        guard let report else { return [] }
        return report.items.filter { selection.contains($0.id) && $0.category.isDeletable }
    }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    /// Highest risk tier among selected items — drives the confirmation sheet (§5.2).
    var maxSelectedRisk: RiskLevel? {
        selectedItems.map(\.riskLevel).max()
    }

    var selectedCount: Int { selectedItems.count }

    var issueCount: Int { report?.issues.count ?? 0 }

    /// "Undo" stays available after a clean for this session (§6 step 5).
    var canUndo: Bool {
        phase == .finished && outcome?.trashed.isEmpty == false && undoResult == nil
    }

    // MARK: Init

    private enum Keys {
        static let enabledCategories = "broom.enabledCategories"
        static let largeFileMB = "broom.largeFileMinimumMB"
    }

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.array(forKey: Keys.enabledCategories) as? [String] {
            let parsed = Set(raw.compactMap(JunkCategory.init(rawValue:)))
            enabledCategories = parsed.isEmpty ? Set(JunkCategory.allCases) : parsed
        } else {
            enabledCategories = Set(JunkCategory.allCases)
        }
        largeFileMinimumMB = defaults.object(forKey: Keys.largeFileMB) as? Int ?? 500
    }

    // MARK: Scanning

    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?
    private var deepestFileTask: Task<Void, Never>?

    func startScan() async {
        guard !isBusy else { return }
        phase = .scanning
        scanProgress = 0
        outcome = nil
        undoResult = nil
        lastErrorMessage = nil
        selection = []
        hasFullDiskAccess = FullDiskAccess.hasAccess()

        var configuration = ScanConfiguration()
        configuration.enabledCategories = enabledCategories
        configuration.largeFileMinimumSize = Int64(largeFileMinimumMB) * 1024 * 1024

        let rules = RulesEngine()
        let engine = ScanEngine(rules: rules)

        scanTask = Task {
            let report = await engine.scan(configuration: configuration) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.scanProgress = max(self?.scanProgress ?? 0, progress.fractionCompleted)
                }
            }
            guard !Task.isCancelled else {
                self.phase = .idle
                return
            }
            self.report = report
            self.scanProgress = 1
            self.phase = .review
            self.applyDefaultSelection()
        }
        await scanTask?.value
    }

    /// Preselect everything except high-risk items: convenient, but the user still
    /// reviews and presses Clean, and backups demand explicit opt-in (§5.2).
    private func applyDefaultSelection() {
        guard let report else { return }
        selection = Set(
            report.items
                .filter { $0.category.isDeletable && $0.riskLevel < .high }
                .map(\.id)
        )
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if phase == .scanning { phase = report == nil ? .idle : .review }
    }

    // MARK: Selection

    func toggle(_ item: JunkItem) {
        guard item.category.isDeletable else { return }
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    func selectAll(in category: JunkCategory, _ select: Bool) {
        guard let report else { return }
        for item in report.items where item.category == category && item.category.isDeletable {
            if select {
                // High-risk items are never bulk-selected.
                if item.riskLevel < .high { selection.insert(item.id) }
            } else {
                selection.remove(item.id)
            }
        }
    }

    func isFullySelected(_ category: JunkCategory) -> Bool {
        let eligible = (report?.items ?? []).filter {
            $0.category == category && $0.category.isDeletable && $0.riskLevel < .high
        }
        return !eligible.isEmpty && eligible.allSatisfy { selection.contains($0.id) }
    }

    // MARK: Cleaning

    func performClean() async {
        guard !selectedItems.isEmpty, !isBusy else { return }
        phase = .cleaning
        cleanProgress = 0
        currentItemName = ""

        let items = selectedItems
        let rules = RulesEngine()
        let undoLog: UndoLog
        do {
            undoLog = try UndoLog()
        } catch {
            lastErrorMessage = "Could not open the undo log: \(error.localizedDescription)"
            phase = .review
            return
        }
        let deleter = SafeDeleter(rules: rules, undoLog: undoLog)

        cleanTask = Task {
            let result = await deleter.trash(items) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.cleanProgress = max(self?.cleanProgress ?? 0, progress.fractionCompleted)
                    self?.currentItemName = progress.currentItem?.displayPath ?? ""
                }
            }
            self.outcome = result
            self.phase = .finished
            self.currentItemName = ""
            // Keep only still-selected-but-failed items visible for a retry.
            let failedPaths = Set(result.failures.map { $0.item.id })
            self.selection = failedPaths
        }
        await cleanTask?.value
    }

    func cancelClean() {
        cleanTask?.cancel()
        cleanTask = nil
    }

    func resetToReview() {
        phase = .review
        outcome = nil
        undoResult = nil
    }

    func finishAndRescan() {
        phase = .idle
        report = nil
        outcome = nil
        selection = []
    }

    // MARK: Undo

    func undoLastClean() async {
        guard let outcome else { return }
        do {
            let log = try UndoLog()
            let restorer = UndoRestorer()
            let entries = await log.entriesForLastClean()
            guard entries.first?.cleanID == outcome.cleanID else {
                lastErrorMessage = "The undo log no longer matches this clean."
                return
            }
            undoResult = restorer.restore(entries)
            if undoResult?.skipped.isEmpty == false {
                lastErrorMessage = "Some items could not be restored: " +
                    (undoResult?.skipped.first?.reason ?? "")
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: Deepest file

    /// Walks the home folder for the most deeply nested file and flags whether Broom may
    /// delete it. Read-only; cancellable at any time.
    func findDeepestFile() async {
        guard !isFindingDeepestFile else { return }
        isFindingDeepestFile = true
        deepestFile = nil
        deepestFileFilesExamined = 0
        suggestions = []
        suggestionMessage = nil
        trashedSuggestionPaths = []
        lastSuggestionDelete = nil

        let finder = DeepestFileFinder()
        deepestFileTask = Task {
            let result = await finder.findDeepestFile { [weak self] examined in
                Task { @MainActor [weak self] in
                    self?.deepestFileFilesExamined = max(self?.deepestFileFilesExamined ?? 0, examined)
                }
            }
            // A cancelled run already reset the state in cancelDeepestFileSearch().
            guard !Task.isCancelled else { return }
            self.isFindingDeepestFile = false
            self.deepestFile = result
            self.suggestions = result?.suggestions ?? []
            self.hasSearchedDeepestFile = true
        }
        await deepestFileTask?.value
    }

    func cancelDeepestFileSearch() {
        deepestFileTask?.cancel()
        deepestFileTask = nil
        isFindingDeepestFile = false
    }

    func revealDeepestFileInFinder() {
        guard let deepestFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([deepestFile.path])
    }

    /// Moves the given suggestions to the Trash right away (recoverable; undo offered).
    /// `SafeDeleter` re-runs every safety gate per file, so a stale suggestion is skipped,
    /// never forced.
    func deleteSuggestions(_ toDelete: [DeepestFileFinder.Suggestion]) async {
        guard !toDelete.isEmpty, !isDeletingSuggestions, phase != .cleaning else { return }
        isDeletingSuggestions = true
        defer { isDeletingSuggestions = false }

        let undoLog: UndoLog
        do {
            undoLog = try UndoLog()
        } catch {
            suggestionMessage = "Could not open the undo log: \(error.localizedDescription)"
            return
        }
        let deleter = SafeDeleter(rules: RulesEngine(), undoLog: undoLog)
        let outcome = await deleter.trash(toDelete.map(\.item))

        let trashedIDs = Set(outcome.trashed.map { $0.item.id })
        suggestions.removeAll { trashedIDs.contains($0.id) }
        trashedSuggestionPaths.formUnion(trashedIDs)
        lastSuggestionDelete = trashedIDs.isEmpty
            ? nil
            : (outcome.cleanID, toDelete.filter { trashedIDs.contains($0.id) })

        var message = "Moved \(outcome.trashed.count) file\(outcome.trashed.count == 1 ? "" : "s") " +
            "(\(ByteFormat.string(outcome.freedBytes))) to the Trash."
        if let failure = outcome.failures.first {
            message += " \(outcome.failures.count) skipped: \(failure.reason)"
        }
        suggestionMessage = message
    }

    func undoSuggestionDelete() async {
        guard let last = lastSuggestionDelete else { return }
        do {
            let log = try UndoLog()
            let entries = await log.all().filter { $0.cleanID == last.cleanID }
            let result = UndoRestorer().restore(entries)
            let restoredPaths = Set(result.restored.map(\.originalPath))

            suggestions.append(contentsOf: last.items.filter { restoredPaths.contains($0.id) })
            suggestions.sort { $0.depth != $1.depth ? $0.depth > $1.depth : $0.id < $1.id }
            trashedSuggestionPaths.subtract(restoredPaths)
            lastSuggestionDelete = nil

            suggestionMessage = "Restored \(result.restored.count) file\(result.restored.count == 1 ? "" : "s")."
            if let skipped = result.skipped.first {
                suggestionMessage? += " \(result.skipped.count) could not be restored: \(skipped.reason)"
            }
        } catch {
            suggestionMessage = error.localizedDescription
        }
    }

    // MARK: Permission UX (§5.1)

    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.hasAccess()
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsDeepLink)
    }
}
