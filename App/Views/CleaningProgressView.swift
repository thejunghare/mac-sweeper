import CleanerCore
import SwiftUI

/// Deletion in progress (§6 step 4): item-by-item; Stop lives in the toolbar.
struct CleaningProgressView: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        ProgressPanel(
            title: "Moving to Trash",
            value: model.cleanProgress,
            caption: model.currentItemName.isEmpty ? nil : model.currentItemName
        )
    }
}
