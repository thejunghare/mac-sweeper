import AppKit
import CleanerCore
import SwiftUI

/// The one status shown on every file row: symbol + two words. Colour is never the only
/// signal (§12.5); the longer "why" lives in the row's tooltip.
struct FlagChip: View {
    let flag: DeleteFlag

    var body: some View {
        Label {
            Text(title).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.caption)
        .fixedSize()
        .accessibilityLabel(title)
    }

    private var title: String {
        switch flag {
        case .safe: return "Safe"
        case .checkFirst: return "Check first"
        case .cannotDelete: return "Can't delete"
        }
    }

    private var symbol: String {
        switch flag {
        case .safe: return "checkmark.circle.fill"
        case .checkFirst: return "exclamationmark.circle.fill"
        case .cannotDelete: return "minus.circle.fill"
        }
    }

    private var tint: Color {
        switch flag {
        case .safe: return .green
        case .checkFirst: return .orange
        case .cannotDelete: return .secondary
        }
    }
}

extension DeleteFlag {
    /// Flag for a scan result: informational categories are never deleted in-app.
    init(_ item: JunkItem) {
        if !item.category.isDeletable {
            self = .cannotDelete
        } else {
            self = item.riskLevel == .low ? .safe : .checkFirst
        }
    }

    /// Flag for a deletion verdict.
    init(_ verdict: DeepestFileFinder.Verdict) {
        if !verdict.canDelete {
            self = .cannotDelete
        } else {
            self = verdict.riskLevel == .low ? .safe : .checkFirst
        }
    }
}

/// Shared file row: Finder icon · name over path · size · flag · trash button.
/// "Show in Finder" lives in the context menu to keep the row quiet.
struct FileRow: View {
    let url: URL
    let path: String
    let size: Int64
    let flag: DeleteFlag
    /// Tooltip explaining the flag.
    let note: String
    var isBusy = false
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(FileManager.default.displayName(atPath: url.path))
                    .lineLimit(1)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Text(ByteFormat.string(size))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            FlagChip(flag: flag)
                .frame(width: 96, alignment: .leading)

            Button {
                onDelete?()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(flag.isDeletable && !isBusy ? Color.red : Color.secondary)
            .disabled(!flag.isDeletable || isBusy || onDelete == nil)
            .help(flag.isDeletable ? "Move to Trash" : note)
            .accessibilityLabel("Move \(url.lastPathComponent) to the Trash")
        }
        .padding(.vertical, 2)
        .help(note)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Bottom strip with the result of the last delete and its Undo.
struct UndoBar: View {
    let message: String
    let canUndo: Bool
    let onUndo: () -> Void

    var body: some View {
        HStack {
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            if canUndo {
                Button("Undo", action: onUndo)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassBar()
    }
}

/// Centered placeholder (ContentUnavailableView is macOS 14+).
struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
