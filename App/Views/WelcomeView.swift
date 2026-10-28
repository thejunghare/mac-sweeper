import CleanerCore
import SwiftUI

/// Landing state: one sentence, one button. Factual, no scare copy (§5.8).
struct WelcomeView: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Free up space")
                .font(.title2.weight(.semibold))

            Text("Find caches, logs and leftovers. You choose what goes to the Trash.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await model.startScan() }
            } label: {
                Text("Scan").frame(minWidth: 100)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 4)
            .accessibilityLabel("Scan for junk files")

            if !model.hasFullDiskAccess {
                fullDiskAccessHint
                    .padding(.top, 12)
            }
        }
        .padding(40)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fullDiskAccessHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
            Text("Some folders need Full Disk Access.")
            Button("Grant…") { model.openFullDiskAccessSettings() }
                .buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .help(FullDiskAccess.explanation)
        .onAppear { model.refreshFullDiskAccess() }
    }
}
