import CleanerCore
import SwiftUI

/// Shows the most deeply nested file in the home folder with a clear
/// "Can delete" / "Can't delete" flag and the reason behind it.
/// Informational only: nothing here deletes — cleaning stays behind the review flow (§5.2).
struct DeepestFileView: View {
    @EnvironmentObject private var model: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Deepest File", systemImage: "arrow.down.to.line")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding()
            .glassBar()

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Text("""
                    Walks your home folder — like `find ~ -type f` in Terminal — and shows \
                    the most deeply nested file, plus whether Broom is allowed to delete it. \
                    Read-only: nothing is changed.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack {
                if model.isFindingDeepestFile {
                    Button("Cancel") { model.cancelDeepestFileSearch() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button(model.hasSearchedDeepestFile ? "Search Again" : "Find Deepest File") {
                        Task { await model.findDeepestFile() }
                    }
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
        .frame(width: 600, height: 480)
        .onAppear {
            if !model.hasSearchedDeepestFile && !model.isFindingDeepestFile {
                Task { await model.findDeepestFile() }
            }
        }
    }

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
            resultCard(result)
        } else if model.hasSearchedDeepestFile {
            Text("No files found in your home folder.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resultCard(_ result: DeepestFileFinder.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
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
                DeletableFlag(canDelete: result.verdict.canDelete)
            }

            Text(result.verdict.reason)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let category = result.verdict.category, let risk = result.verdict.riskLevel {
                HStack(spacing: 6) {
                    Label(category.displayName, systemImage: category.symbolName)
                        .font(.caption)
                    RiskBadge(risk: risk)
                }
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

            Button {
                model.revealDeepestFileInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
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
