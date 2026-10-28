import CleanerCore
import SwiftUI

/// Deep Clean: the most deeply nested file in the home folder (like
/// `find ~ -type f | awk -F/ '{print NF}' | sort -n | tail -1`) with its flag, then the
/// files that are safe to remove, largest first.
///
/// Safety (§5.2): the trash button is Move to Trash (Undo offered), `SafeDeleter`
/// re-validates every file, high-risk data is never suggested, and "Delete All" asks once.
struct DeepestFileView: View {
    @EnvironmentObject private var model: ScanViewModel
    @State private var confirmDeleteAll = false

    private var suggestionsBySize: [DeepestFileFinder.Suggestion] {
        model.suggestions.sorted { $0.item.size > $1.item.size }
    }

    var body: some View {
        content
            .navigationTitle("Deep Clean")
            .safeAreaInset(edge: .bottom) {
                if let message = model.suggestionMessage {
                    UndoBar(message: message, canUndo: model.canUndoSuggestionDelete) {
                        Task { await model.undoSuggestionDelete() }
                    }
                }
            }
            .alert("Move \(model.suggestions.count) files to the Trash?", isPresented: $confirmDeleteAll) {
                Button("Move to Trash", role: .destructive) {
                    Task { await model.deleteSuggestions(model.suggestions) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(ByteFormat.string(model.suggestionsTotalSize)). You can undo.")
            }
            .onAppear {
                if !model.hasSearchedDeepestFile && !model.isFindingDeepestFile {
                    Task { await model.findDeepestFile() }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.isFindingDeepestFile {
            ProgressPanel(
                title: "Searching",
                value: nil,
                caption: "\(model.deepestFileFilesExamined.formatted()) files examined"
            )
        } else if let result = model.deepestFile {
            List {
                Section("Deepest file · \(result.depth) levels") {
                    deepestRow(result)
                }

                Section {
                    ForEach(suggestionsBySize) { suggestion in
                        FileRow(
                            url: suggestion.item.path,
                            path: suggestion.item.displayPath,
                            size: suggestion.item.size,
                            flag: DeleteFlag(suggestion.item),
                            note: suggestion.item.category.displayName,
                            isBusy: model.isDeletingSuggestions
                        ) {
                            Task { await model.deleteSuggestions([suggestion]) }
                        }
                    }
                } header: {
                    suggestionsHeader
                } footer: {
                    if result.unreadableDirectories > 0 {
                        Text("\(result.unreadableDirectories.formatted()) folders skipped — needs Full Disk Access")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        } else if model.hasSearchedDeepestFile {
            EmptyStateView(symbol: "doc", title: "No files found")
        }
    }

    /// Delete is offered for the deepest file only when it's also a suggestion
    /// (deletable and not high-risk).
    private func deleteAction(for result: DeepestFileFinder.Result) -> (() -> Void)? {
        guard let suggestion = model.suggestions.first(where: { $0.id == result.path.path }) else {
            return nil
        }
        return { Task { await model.deleteSuggestions([suggestion]) } }
    }

    @ViewBuilder
    private func deepestRow(_ result: DeepestFileFinder.Result) -> some View {
        if model.trashedSuggestionPaths.contains(result.path.path) {
            Label("\(result.path.lastPathComponent) moved to the Trash", systemImage: "trash")
                .foregroundStyle(.secondary)
        } else {
            FileRow(
                url: result.path,
                path: result.displayPath,
                size: result.size,
                flag: DeleteFlag(result.verdict),
                note: result.verdict.reason,
                isBusy: model.isDeletingSuggestions,
                onDelete: deleteAction(for: result)
            )
        }
    }

    private var suggestionsHeader: some View {
        HStack {
            Text(model.suggestions.isEmpty
                 ? "Nothing safe to remove"
                 : "Safe to remove · \(ByteFormat.string(model.suggestionsTotalSize))")
            Spacer()
            if !model.suggestions.isEmpty {
                Button {
                    confirmDeleteAll = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(model.isDeletingSuggestions)
                .help("Move all to the Trash")
                .accessibilityLabel("Move all suggested files to the Trash")
            }
        }
        .textCase(nil)
    }
}
