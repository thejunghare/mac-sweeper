import CleanerCore
import SwiftUI

/// Live progress during deletion (§6 step 4): item-by-item, cancellable.
struct CleaningProgressView: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            ProgressView(value: model.cleanProgress) {
                Text("Moving items to the Trash…")
                    .font(.title3)
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 420)
            .accessibilityLabel("Cleaning, \(Int(model.cleanProgress * 100)) percent complete")

            Text("\(Int(model.cleanProgress * 100))%")
                .font(.system(.title2, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.spring, value: model.cleanProgress)

            Text(model.currentItemName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)

            Text("You can cancel — completed items stay in the Trash and remain restorable.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Cancel Clean") {
                model.cancelClean()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
