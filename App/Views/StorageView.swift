import AppKit
import CleanerCore
import SwiftUI

/// Storage screen modelled on System Settings → Storage: pick a section, see what's in it,
/// and act on each item directly. Every item carries one flag — Safe to delete, Check first,
/// or Can't delete — and a Delete button (Move to Trash, with Undo).
struct StorageView: View {
    @StateObject private var model = StorageViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 270)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Button {
                    model.analyze()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isAnalyzing || model.isDeleting)
                if model.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    model.cancel()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .glassBar()
        }
        .frame(width: 1000, height: 700)
        .onAppear { model.analyze() }
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
            Text(confirmationMessage)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let usage = model.diskUsage {
                DiskUsageHeader(usage: usage)
                    .padding(14)
                Divider()
            }

            List(selection: $model.selectedSection) {
                ForEach(StorageSection.allCases) { section in
                    sectionRow(section)
                        .tag(section as StorageSection?)
                }
                Section {
                    managedRow("macOS", symbol: "laptopcomputer")
                    managedRow("Other Users & Shared", symbol: "person.2")
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func sectionRow(_ section: StorageSection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbolName)
                .frame(width: 22)
                .foregroundStyle(.tint)
            Text(section.displayName)
            Spacer()
            if let report = model.reports[section] {
                Text(ByteFormat.string(report.totalSize))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if model.isAnalyzing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func managedRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 22)
            Text(title)
            Spacer()
            Text("macOS manages").font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        let section = model.selectedSection ?? .applications
        VStack(alignment: .leading, spacing: 0) {
            detailHeader(section)
                .padding(16)

            if let message = model.message {
                messageBanner(message)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            Divider()

            if let report = model.reports[section] {
                if report.entries.isEmpty {
                    Text("Nothing here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(report.entries) { entry in
                            StorageEntryRow(entry: entry, isBusy: model.isDeleting) {
                                model.requestDelete([entry])
                            } onReveal: {
                                model.reveal(entry)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            } else {
                ProgressView("Measuring \(section.displayName)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func detailHeader(_ section: StorageSection) -> some View {
        let report = model.reports[section]
        let safe = report?.safeEntries ?? []
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: section.symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.displayName).font(.title3.weight(.semibold))
                if let report {
                    Text("\(report.entries.count) items · \(ByteFormat.string(report.totalSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if section == .trash {
                Button {
                    model.openTrash()
                } label: {
                    Label("Open Trash to Empty", systemImage: "trash")
                }
            }
            if !safe.isEmpty {
                Button(role: .destructive) {
                    model.requestDelete(safe)
                } label: {
                    Label(
                        "Delete All Safe (\(ByteFormat.string(safe.reduce(0) { $0 + $1.size })))",
                        systemImage: "trash"
                    )
                }
                .disabled(model.isDeleting)
            }
        }
    }

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.canUndo {
                Button {
                    Task { await model.undoLastDelete() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
            }
        }
        .padding(10)
        .glassCard()
    }

    // MARK: Confirmation

    private var confirmationTitle: String {
        let count = model.pendingConfirmation.count
        return count == 1
            ? "Move “\(model.pendingConfirmation[0].path.lastPathComponent)” to the Trash?"
            : "Move \(count) items to the Trash?"
    }

    private var confirmationMessage: String {
        let size = model.pendingConfirmation.reduce(0) { $0 + $1.size }
        return "\(ByteFormat.string(size)). This includes your own files or apps — " +
            "check you don't need them. You can Undo, and they stay in the Trash until you empty it."
    }
}

// MARK: - Rows & chips

/// One item: Finder icon, name, location, size, flag, Reveal and Delete.
private struct StorageEntryRow: View {
    let entry: StorageEntry
    let isBusy: Bool
    let onDelete: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path.path))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(FileManager.default.displayName(atPath: entry.path.path))
                    .lineLimit(1)
                Text(entry.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(ByteFormat.string(entry.size))
                .font(.callout)
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)

            FlagChip(flag: entry.flag)
                .help(entry.note)
                .frame(width: 130, alignment: .leading)

            Button(action: onReveal) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(entry.path.lastPathComponent) in Finder")

            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(!entry.flag.isDeletable || isBusy)
            .help(entry.flag.isDeletable ? "Move to Trash (you can undo)" : entry.note)
            .accessibilityLabel("Move \(entry.path.lastPathComponent) to the Trash")
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }
}

/// The single flag shown instead of risk tiers: colour + symbol + two-word text.
struct FlagChip: View {
    let flag: DeleteFlag

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .fixedSize()
            .accessibilityLabel(title)
    }

    private var title: String {
        switch flag {
        case .safe: return "Safe to delete"
        case .checkFirst: return "Check first"
        case .cannotDelete: return "Can't delete"
        }
    }

    private var symbol: String {
        switch flag {
        case .safe: return "checkmark.circle.fill"
        case .checkFirst: return "exclamationmark.circle.fill"
        case .cannotDelete: return "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch flag {
        case .safe: return .green
        case .checkFirst: return .orange
        case .cannotDelete: return .red
        }
    }
}

/// "412 GB of 494 GB used" with a capacity bar.
private struct DiskUsageHeader: View {
    let usage: DiskUsage

    private var fraction: Double {
        usage.totalBytes == 0 ? 0 : Double(usage.usedBytes) / Double(usage.totalBytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(ByteFormat.string(usage.usedBytes)) of \(ByteFormat.string(usage.totalBytes)) used")
                .font(.callout.weight(.semibold))
            ProgressView(value: fraction)
                .tint(fraction > 0.9 ? Color.red : Color.accentColor)
            Text("\(ByteFormat.string(usage.availableBytes)) available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
