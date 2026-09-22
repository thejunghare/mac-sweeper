import CleanerCore
import SwiftUI

/// Review screen (§6 step 2): grouped, selectable list with sizes, dates and risk tiers.
/// No deletion can happen from anywhere except the "Clean…" toolbar action.
struct ReviewView: View {
    @EnvironmentObject private var model: ScanViewModel
    @Binding var selectedCategory: JunkCategory?

    private var visibleCategories: [JunkCategory] {
        if let selectedCategory, model.report != nil {
            let categories = model.categoriesInReport
            return categories.contains(selectedCategory) ? [selectedCategory] : categories
        }
        return model.categoriesInReport
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.report == nil || model.categoriesInReport.isEmpty {
                emptyState
            } else {
                resultList
                summaryBar
            }
        }
    }

    private var resultList: some View {
        List {
            ForEach(visibleCategories, id: \.self) { category in
                Section {
                    ForEach(model.items(in: category)) { item in
                        ItemRow(item: item, isSelected: model.selection.contains(item.id)) {
                            model.toggle(item)
                        }
                    }
                } header: {
                    categoryHeader(category)
                }
            }
        }
        .listStyle(.inset)
    }

    private func categoryHeader(_ category: JunkCategory) -> some View {
        HStack(spacing: 8) {
            Image(systemName: category.symbolName)
                .foregroundStyle(riskColor(category.riskLevel))
            Text(category.displayName)
            RiskBadge(risk: category.riskLevel)
            if !category.isDeletable {
                Text("informational only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .italic()
            }
            Spacer()
            Text(ByteFormat.string(model.size(in: category)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if category.isDeletable && category.riskLevel < .high {
                Button(model.isFullySelected(category) ? "Deselect" : "Select") {
                    model.selectAll(in: category, !model.isFullySelected(category))
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityLabel("\(model.isFullySelected(category) ? "Deselect" : "Select") all \(category.displayName) items")
            }
        }
        .font(.subheadline)
        .textCase(nil)
    }

    private var summaryBar: some View {
        HStack {
            if let risk = model.maxSelectedRisk {
                RiskBadge(risk: risk)
                Text(risk == .high
                     ? "\(model.selectedCount) items include HIGH-RISK data — you'll confirm specifically"
                     : "\(model.selectedCount) items selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormat.string(model.selectedSize))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .accessibilityLabel("\(ByteFormat.string(model.selectedSize)) selected for cleaning")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassBar()
    }

    private var emptyState: some View {
        ContentUnavailableCompatView()
    }
}

/// A row in the review list: checkbox (deletable only), name, path, date, size, risk.
struct ItemRow: View {
    @EnvironmentObject private var model: ScanViewModel
    let item: JunkItem
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if item.category.isDeletable {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(" ", modifiers: [])
                .accessibilityLabel("\(isSelected ? "Deselect" : "Select") \(item.path.lastPathComponent)")
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Informational item, not deletable by Broom")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.path.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                Text(item.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let date = item.modificationDate {
                Text(date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RiskBadge(risk: item.riskLevel)

            Text(ByteFormat.string(item.size))
                .font(.callout)
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: item.category.isDeletable ? onToggle : {})
        .accessibilityElement(children: .combine)
    }
}

struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        Text(risk.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel("Risk: \(risk.displayName)")
    }

    private var tint: Color { riskColor(risk) }
}

func riskColor(_ risk: RiskLevel) -> Color {
    switch risk {
    case .low: return .green
    case .medium: return .orange
    case .high: return .red
    }
}

/// ContentUnavailableView is macOS 14+; provide a look-alike for the macOS 13 floor.
struct ContentUnavailableCompatView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Results")
                .font(.title3)
            Text("Run a scan, or adjust the filter, to see reclaimable files.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
