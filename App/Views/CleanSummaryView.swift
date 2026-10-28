import CleanerCore
import SwiftUI

/// Post-clean summary (§6 step 5): freed bytes, skipped items, and Undo for the session.
struct CleanSummaryView: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text("Freed \(ByteFormat.string(model.outcome?.freedBytes ?? 0))")
                .font(.title2.weight(.semibold))

            Text("\(model.outcome?.trashed.count ?? 0) items moved to the Trash")
                .foregroundStyle(.secondary)

            if let status = statusLine {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let failures = model.outcome?.failures, !failures.isEmpty {
                failureList(failures)
            }

            HStack(spacing: 10) {
                if model.canUndo {
                    Button("Undo") {
                        Task { await model.undoLastClean() }
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    .accessibilityLabel("Undo the last clean")
                }
                Button("Done") {
                    model.finishAndRescan()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusLine: String? {
        if let error = model.lastErrorMessage { return error }
        guard let undo = model.undoResult else { return nil }
        return undo.restored.isEmpty
            ? "Nothing was restored: \(undo.skipped.first?.reason ?? "unknown reason")"
            : "Restored \(undo.restored.count) items"
    }

    private func failureList(_ failures: [SafeDeleter.Failure]) -> some View {
        DisclosureGroup("\(failures.count) skipped") {
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
        }
        .font(.callout)
    }
}
