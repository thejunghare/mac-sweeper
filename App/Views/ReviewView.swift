import CleanerCore
import SwiftUI

/// Review screen (§6 step 2): grouped, selectable results. Nothing is deleted from here
/// except through "Clean…", which opens the confirmation sheet.
struct ReviewView: View {
    @EnvironmentObject private var model: ScanViewModel
    let onClean: () -> Void

    var body: some View {
        Group {
            if model.categoriesInReport.isEmpty {
                EmptyStateView(symbol: "sparkles", title: "Nothing to clean")
            } else {
                List {
                    ForEach(model.categoriesInReport, id: \.self) { category in
                        let items = model.items(in: category)
                        if !items.isEmpty {
                            Section {
                                ForEach(items) { item in
                                    ItemRow(item: item, isSelected: model.selection.contains(item.id)) {
                                        model.toggle(item)
                                    }
                                }
                            } header: {
                                categoryHeader(category)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .safeAreaInset(edge: .bottom) { summaryBar }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter")
    }

    private func categoryHeader(_ category: JunkCategory) -> some View {
        HStack(spacing: 8) {
            Label(category.displayName, systemImage: category.symbolName)
            Spacer()
            Text(ByteFormat.string(model.size(in: category)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if category.isDeletable && category.riskLevel < .high {
                let all = model.isFullySelected(category)
                Button(all ? "Deselect" : "Select All") {
                    model.selectAll(in: category, !all)
                }
                .buttonStyle(.link)
                .accessibilityLabel("\(all ? "Deselect" : "Select") all \(category.displayName)")
            }
        }
        .font(.subheadline)
        .textCase(nil)
        .help(category.explanation)
    }

    private var summaryBar: some View {
        HStack {
            Text(model.selectedCount == 0
                 ? "Nothing selected"
                 : "\(model.selectedCount) selected · \(ByteFormat.string(model.selectedSize))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Clean…", action: onClean)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedCount == 0)
                .accessibilityLabel("Clean selected items")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassBar()
    }
}

/// Scan result row: checkbox (deletable only), name over path, size, flag.
struct ItemRow: View {
    let item: JunkItem
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if item.category.isDeletable {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                } else {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(.tertiary)
                }
            }
            .imageScale(.large)
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.path.lastPathComponent)
                    .lineLimit(1)
                Text(item.detail ?? item.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Text(ByteFormat.string(item.size))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            FlagChip(flag: DeleteFlag(item))
                .frame(width: 96, alignment: .leading)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if item.category.isDeletable { onToggle() } }
        .help(item.category.isDeletable ? item.displayPath : "Review it and delete it in Finder yourself")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.path.lastPathComponent), \(ByteFormat.string(item.size))")
        .accessibilityAddTraits(item.category.isDeletable ? .isButton : [])
        .accessibilityValue(item.category.isDeletable ? (isSelected ? "Selected" : "Not selected") : "Can't delete")
    }
}
