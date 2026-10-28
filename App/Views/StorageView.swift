import CleanerCore
import SwiftUI

/// Storage, laid out like System Settings → Storage: disk usage, then one row per section;
/// open a section to see its files, each with a flag and a trash button (Move to Trash,
/// with Undo). "Check first" items ask once; "Can't delete" items only offer Show in Finder.
struct StorageView: View {
    @EnvironmentObject private var model: StorageViewModel

    var body: some View {
        NavigationStack {
            List {
                if let usage = model.diskUsage {
                    Section {
                        DiskUsageRow(usage: usage)
                    }
                }
                Section {
                    ForEach(StorageSection.allCases) { section in
                        NavigationLink(value: section) {
                            sectionRow(section)
                        }
                    }
                }
                Section {
                    managedRow("macOS", symbol: "laptopcomputer")
                    managedRow("Other Users & Shared", symbol: "person.2")
                }
            }
            .listStyle(.inset)
            .navigationTitle("Storage")
            .navigationDestination(for: StorageSection.self) { section in
                StorageSectionView(section: section)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.message {
                UndoBar(message: message, canUndo: model.canUndo) {
                    Task { await model.undoLastDelete() }
                }
            }
        }
        .alert(
            confirmationTitle,
            isPresented: Binding(
                get: { !model.pendingConfirmation.isEmpty },
                set: { if !$0 { model.pendingConfirmation = [] } }
            )
        ) {
            Button("Move to Trash", role: .destructive) { model.confirmPendingDelete() }
            Button("Cancel", role: .cancel) { model.pendingConfirmation = [] }
        } message: {
            Text("\(ByteFormat.string(pendingSize)). You can undo.")
        }
        .onAppear { model.analyzeIfNeeded() }
    }

    private func sectionRow(_ section: StorageSection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(section.displayName)
            Spacer()
            if let report = model.reports[section] {
                Text(ByteFormat.string(report.totalSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if model.isAnalyzing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func managedRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 22)
            Text(title)
            Spacer()
            FlagChip(flag: .cannotDelete)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .help("Managed by macOS")
    }

    private var pendingSize: Int64 {
        model.pendingConfirmation.reduce(0) { $0 + $1.size }
    }

    private var confirmationTitle: String {
        let pending = model.pendingConfirmation
        return pending.count == 1
            ? "Move “\(pending[0].path.lastPathComponent)” to the Trash?"
            : "Move \(pending.count) items to the Trash?"
    }
}

/// One section's files, largest first.
private struct StorageSectionView: View {
    @EnvironmentObject private var model: StorageViewModel
    let section: StorageSection

    var body: some View {
        Group {
            if let report = model.reports[section] {
                if report.entries.isEmpty {
                    EmptyStateView(symbol: section.symbolName, title: "Nothing here")
                } else {
                    List(report.entries) { entry in
                        FileRow(
                            url: entry.path,
                            path: entry.displayPath,
                            size: entry.size,
                            flag: entry.flag,
                            note: entry.note,
                            isBusy: model.isDeleting
                        ) {
                            model.requestDelete([entry])
                        }
                    }
                    .listStyle(.inset)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(section.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if section == .trash {
                    Button {
                        model.openTrash()
                    } label: {
                        Label("Open Trash", systemImage: "arrow.up.forward.app")
                    }
                    .help("Open the Trash in Finder to empty it")
                }
                let safe = model.reports[section]?.safeEntries ?? []
                let safeSize = safe.reduce(Int64(0)) { $0 + $1.size }
                if !safe.isEmpty {
                    Button {
                        model.requestDelete(safe)
                    } label: {
                        Label("Delete Safe", systemImage: "trash")
                    }
                    .disabled(model.isDeleting)
                    .help("Move all safe items (\(ByteFormat.string(safeSize))) to the Trash")
                }
            }
        }
    }
}

/// "412 GB of 494 GB used" over a capacity bar.
private struct DiskUsageRow: View {
    let usage: DiskUsage

    private var fraction: Double {
        usage.totalBytes == 0 ? 0 : Double(usage.usedBytes) / Double(usage.totalBytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(ByteFormat.string(usage.usedBytes)) of \(ByteFormat.string(usage.totalBytes)) used")
                Spacer()
                Text("\(ByteFormat.string(usage.availableBytes)) free")
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            ProgressView(value: fraction)
                .tint(fraction > 0.9 ? Color.red : Color.accentColor)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
