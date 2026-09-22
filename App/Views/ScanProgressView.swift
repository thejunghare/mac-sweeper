import CleanerCore
import SwiftUI

/// Scan-in-progress state with a cancellable progress indicator (§5.8: Cancel always
/// available; §12.4: spring animations, system feedback).
struct ScanProgressView: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            ProgressView(value: model.scanProgress) {
                Text("Scanning…")
                    .font(.title3)
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 420)
            .accessibilityLabel("Scanning, \(Int(model.scanProgress * 100)) percent complete")

            Text("\(Int(model.scanProgress * 100))%")
                .font(.system(.title2, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.spring, value: model.scanProgress)

            Text("Reading folder sizes — nothing is being changed.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !model.hasFullDiskAccess {
                Label("Some locations are skipped without Full Disk Access.",
                      systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
