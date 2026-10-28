import CleanerCore
import SwiftUI

/// Risk-tiered confirmation (§5.2):
/// - low/medium selection → single explicit confirmation listing scope + total;
/// - any HIGH-risk item selected → second gate: the user must type DELETE, with the
///   full path list visible. Nothing is ever deleted without this sheet.
struct CleanConfirmationSheet: View {
    @EnvironmentObject private var model: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var typedConfirmation = ""
    @FocusState private var confirmFieldFocused: Bool

    private var needsTypeToConfirm: Bool { model.maxSelectedRisk == .high }
    private var typedCorrectly: Bool { !needsTypeToConfirm || typedConfirmation == "DELETE" }

    private var grouped: [(category: JunkCategory, items: [JunkItem])] {
        JunkCategory.allCases.compactMap { category in
            let items = model.selectedItems.filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 520, height: 440)
        .onAppear { if needsTypeToConfirm { confirmFieldFocused = true } }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Move \(model.selectedCount) items to the Trash?")
                .font(.title3.weight(.semibold))
            Text("\(ByteFormat.string(model.selectedSize)) · You can undo.")
                .foregroundStyle(.secondary)

            if needsTypeToConfirm {
                highRiskWarning
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var highRiskWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Includes an iPhone/iPad backup — it may be your only copy.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
            TextField("Type DELETE to confirm", text: $typedConfirmation)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($confirmFieldFocused)
                .accessibilityLabel("Type DELETE to confirm high-risk deletion")
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var list: some View {
        List {
            ForEach(grouped, id: \.category) { group in
                Section {
                    ForEach(group.items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.path.lastPathComponent)
                                .font(.body)
                            Text(item.displayPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    HStack {
                        Label(group.category.displayName, systemImage: group.category.symbolName)
                        Spacer()
                        Text(ByteFormat.string(group.items.reduce(0) { $0 + $1.size }))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                dismiss()
                onConfirm()
            } label: {
                Text("Move to Trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(needsTypeToConfirm ? .red : .accentColor)
            .disabled(!typedCorrectly)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Move \(model.selectedCount) selected items to the Trash")
        }
        .padding()
    }
}
