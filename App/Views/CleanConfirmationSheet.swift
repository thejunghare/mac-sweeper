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
        .frame(width: 640, height: 520)
        .onAppear { if needsTypeToConfirm { confirmFieldFocused = true } }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Label("Confirm Clean", systemImage: "trash")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    onCancel()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel and close")
            }
            Text("""
                These \(model.selectedCount) items (\(ByteFormat.string(model.selectedSize))) \
                will be moved to the Trash. Nothing is permanently deleted — you can empty \
                the Trash yourself later, or use Undo.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if needsTypeToConfirm {
                highRiskWarning
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassBar()
    }

    private var highRiskWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("High-risk selection includes iOS device backups", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            Text("A device backup may be your only copy of data from that iPhone or iPad. Deleting it is only reversible if a copy exists elsewhere. Type DELETE to enable the button.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
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
                        RiskBadge(risk: group.category.riskLevel)
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
                Label("Move to Trash",
                      systemImage: needsTypeToConfirm ? "trash.fill" : "trash")
                    .font(.body.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(needsTypeToConfirm ? .red : .accentColor)
            .disabled(!typedCorrectly)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Move \(model.selectedCount) selected items to the Trash")
        }
        .padding()
        .glassBar()
    }
}
