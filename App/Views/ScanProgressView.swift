import CleanerCore
import SwiftUI

/// Scan in progress. Stop lives in the toolbar (§5.8: Cancel always available).
struct ScanProgressView: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        ProgressPanel(title: "Scanning", value: model.scanProgress, caption: "Read-only — nothing is changed")
    }
}

/// Shared progress layout for scanning and cleaning.
struct ProgressPanel: View {
    let title: String
    /// `nil` = indeterminate.
    let value: Double?
    var caption: String?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                if let value {
                    Text("\(Int(value * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: value)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { "\(title), \(Int($0 * 100)) percent" } ?? title)
    }
}
