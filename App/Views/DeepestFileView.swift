import AppKit
import CleanerCore
import SwiftUI

/// "Deep Clean": walks the home folder, shows the most deeply nested file with a clear
/// "Can delete" / "Can't delete" flag, and lists files that are safe to remove — each with
/// a direct Delete button.
///
/// Safety (§5.2): Delete always means *Move to Trash* (recoverable, with Undo here), every
/// file is re-validated by `SafeDeleter` at delete time, high-risk data is never offered,
/// and bulk "Delete All" asks once before acting.
struct DeepestFileView: View {
    @EnvironmentObject private var model: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    private enum SortOrder: String, CaseIterable, Identifiable {
        case deepest = "Deepest"
        case largest = "Largest"
        var id: String { rawValue }
    }

    @State private var sortOrder: SortOrder = .deepest
    @State private var confirmDeleteAll = false

    private var sortedSuggestions: [DeepestFileFinder.Suggestion] {
        switch sortOrder {
        case .deepest: return model.suggestions
        case .largest: return model.suggestions.sorted { $0.item.size > $1.item.size }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Deep Clean", systemImage: "arrow.down.to.line")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding()
            .glassBar()

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            footer
        }
        .frame(width: 720, height: 680)
        .onAppear {
            if !model.hasSearchedDeepestFile && !model.isFindingDeepestFile {
                Task { await model.findDeepestFile() }
            }
        }
        .alert(
            "Move \(model.suggestions.count) files to the Trash?",
            isPresented: $confirmDeleteAll
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.deleteSuggestions(model.suggestions) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                \(ByteFormat.string(model.suggestionsTotalSize)) of cache, log and build files. \
                They stay in the Trash until you empty it, and you can Undo here.
                """)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.isFindingDeepestFile {
            VStack(spacing: 10) {
                ProgressView()
                Text("Examined \(model.deepestFileFilesExamined.formatted()) files…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else if let result = model.deepestFile {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("""
                        Walks your home folder — like `find ~ -type f` in Terminal — shows the \
                        most deeply nested file, and suggests files that are safe to remove.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let message = model.suggestionMessage {
                        messageBanner(message)
                    }

                    resultCard(result)
                    suggestionsSection
                }
                .padding(20)
            }
        } else if model.hasSearchedDeepestFile {
            Text("No files found in your home folder.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            if model.isFindingDeepestFile {
                Button("Cancel") { model.cancelDeepestFileSearch() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(model.hasSearchedDeepestFile ? "Search Again" : "Find Deepest File") {
                    Task { await model.findDeepestFile() }
                }
                .disabled(model.isDeletingSuggestions)
            }
            Spacer()
            Button("Done") {
                model.cancelDeepestFileSearch()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
        .glassBar()
    }

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.canUndoSuggestionDelete {
                Button {
                    Task { await model.undoSuggestionDelete() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .accessibilityLabel("Undo: put the files back from the Trash")
            }
        }
        .padding(12)
        .glassCard()
    }

    // MARK: Deepest file

    private func resultCard(_ result: DeepestFileFinder.Result) -> some View {
        let isTrashed = model.trashedSuggestionPaths.contains(result.path.path)
        let suggestion = model.suggestions.first { $0.id == result.path.path }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deepest file")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(result.path.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    Text(result.displayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isTrashed {
                    Label("In Trash", systemImage: "trash")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    DeletableFlag(canDelete: result.verdict.canDelete)
                }
            }

            Text(result.verdict.reason)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let category = result.verdict.category {
                Label(category.displayName, systemImage: category.symbolName)
                    .font(.caption)
            }

            Divider()

            details(result)

            if result.unreadableDirectories > 0 {
                Label(
                    "\(result.unreadableDirectories.formatted()) folders couldn't be read — " +
                        "grant Full Disk Access to include them.",
                    systemImage: "lock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                if let suggestion, !isTrashed {
                    Button(role: .destructive) {
                        Task { await model.deleteSuggestions([suggestion]) }
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    .disabled(model.isDeletingSuggestions)
                }
                if !isTrashed {
                    Button {
                        model.revealDeepestFileInFinder()
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .glassCard()
    }

    private func details(_ result: DeepestFileFinder.Result) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Depth").foregroundStyle(.secondary)
                Text("\(result.depth) levels below ~")
            }
            GridRow {
                Text("Size").foregroundStyle(.secondary)
                Text(ByteFormat.string(result.size))
            }
            if let date = result.modificationDate {
                GridRow {
                    Text("Modified").foregroundStyle(.secondary)
                    Text(date, style: .date)
                }
            }
            GridRow {
                Text("Files examined").foregroundStyle(.secondary)
                Text(result.filesExamined.formatted())
            }
            if result.otherFilesAtSameDepth > 0 {
                GridRow {
                    Text("Same depth").foregroundStyle(.secondary)
                    Text("\(result.otherFilesAtSameDepth.formatted()) other files")
                }
            }
        }
        .font(.caption)
        .monospacedDigit()
    }

    // MARK: Suggestions

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggested to remove")
                        .font(.headline)
                    Text(model.suggestions.isEmpty
                         ? "Nothing to suggest — no removable cache, log or build files found."
                         : "\(model.suggestions.count) files · \(ByteFormat.string(model.suggestionsTotalSize)) · " +
                            "regenerated automatically or safe to lose")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.suggestions.isEmpty {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                    .accessibilityLabel("Sort suggestions")

                    Button(role: .destructive) {
                        confirmDeleteAll = true
                    } label: {
                        Label("Delete All…", systemImage: "trash")
                    }
                    .disabled(model.isDeletingSuggestions)
                    .accessibilityLabel("Move all suggested files to the Trash")
                }
            }

            if model.isDeletingSuggestions {
                ProgressView("Moving to Trash…")
                    .controlSize(.small)
            }

            LazyVStack(spacing: 0) {
                ForEach(sortedSuggestions) { suggestion in
                    SuggestionRow(suggestion: suggestion)
                    Divider()
                }
            }
        }
    }
}

/// One suggested file: name, path, category, risk, size, and its direct Delete button.
private struct SuggestionRow: View {
    @EnvironmentObject private var model: ScanViewModel
    let suggestion: DeepestFileFinder.Suggestion

    private var item: JunkItem { suggestion.item }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.category.symbolName)
                .foregroundStyle(riskColor(item.riskLevel))
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.path.lastPathComponent)
                    .lineLimit(1)
                Text(item.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.category.displayName) · depth \(suggestion.depth)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            FlagChip(flag: item.riskLevel == .low ? .safe : .checkFirst)

            Text(ByteFormat.string(item.size))
                .font(.callout)
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.path])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(item.path.lastPathComponent) in Finder")

            Button(role: .destructive) {
                Task { await model.deleteSuggestions([suggestion]) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(model.isDeletingSuggestions)
            .help("Move to Trash (you can undo)")
            .accessibilityLabel("Move \(item.path.lastPathComponent) to the Trash")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

/// The deletable / not-deletable flag: colour *and* symbol *and* text, so it never relies
/// on colour alone (§12.5).
struct DeletableFlag: View {
    let canDelete: Bool

    var body: some View {
        Label(
            canDelete ? "Can delete" : "Can't delete",
            systemImage: canDelete ? "checkmark.shield.fill" : "xmark.shield.fill"
        )
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(0.18), in: Capsule())
        .foregroundStyle(tint)
        .accessibilityLabel(canDelete ? "Broom can delete this file" : "Broom cannot delete this file")
    }

    private var tint: Color { canDelete ? .green : .red }
}
