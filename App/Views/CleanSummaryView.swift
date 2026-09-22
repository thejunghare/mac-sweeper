import CleanerCore
import SwiftUI

/// Post-clean summary (§6 step 5): freed bytes, failures, and Undo for the session.
struct CleanSummaryView: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "checkmark.seal")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text("Freed \(ByteFormat.string(model.outcome?.freedBytes ?? 0))")
                .font(.title2.weight(.semibold))
                .contentTransition(.numericText())

            Text("\(model.outcome?.trashed.count ?? 0) items moved to the Trash. They stay recoverable until you empty the Trash yourself.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let undoResult = model.undoResult {
                if undoResult.restored.isEmpty {
                    Label("Nothing was restored: \(undoResult.skipped.first?.reason ?? "unknown reason")",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Label("Restored \(undoResult.restored.count) items to their original locations.",
                          systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }

            if let failures = model.outcome?.failures, !failures.isEmpty {
                failureList(failures)
            }

            if let error = model.lastErrorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                if model.canUndo {
                    Button {
                        Task { await model.undoLastClean() }
                    } label: {
                        Label("Undo Last Clean", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("z", modifiers: .command)
                    .accessibilityLabel("Undo the last clean")
                }

                Button {
                    model.finishAndRescan()
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button("Scan Again") {
                    Task { await model.startScan() }
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureList(_ failures: [SafeDeleter.Failure]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(failures, id: \.item.id) { failure in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failure.item.path.lastPathComponent)
                            .font(.caption)
                        Text(failure.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            Text("\(failures.count) item(s) could not be moved — they were skipped, not forced.")
                .font(.callout)
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: 480)
    }
}
