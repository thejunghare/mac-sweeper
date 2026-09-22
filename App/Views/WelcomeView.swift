import CleanerCore
import SwiftUI

/// Landing state: honest, factual framing — no fake system alerts, no fear copy (§5.8).
struct WelcomeView: View {
    @EnvironmentObject private var model: ScanViewModel
    @State private var showPrivacy = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "broom")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Find files you can safely remove")
                .font(.title2)

            Text("""
                Broom scans your Mac for caches, logs and leftovers, shows you exactly \
                what it found — with sizes and dates — and moves only what you choose \
                to the Trash. Everything is recoverable until you empty the Trash yourself.
                """)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            if !model.hasFullDiskAccess {
                permissionCard
            }

            Button {
                Task { await model.startScan() }
            } label: {
                Label("Scan for Junk", systemImage: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Scan for junk files")

            Button("What does Broom access and why?") {
                showPrivacy = true
            }
            .buttonStyle(.link)
            .accessibilityLabel("Open the screen explaining what Broom accesses and why")

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showPrivacy) { PrivacyView() }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Full Disk Access not granted", systemImage: "lock")
                .font(.headline)
            Text(FullDiskAccess.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") {
                    model.openFullDiskAccessSettings()
                }
                .buttonStyle(.bordered)
                Button("Re-check") {
                    model.refreshFullDiskAccess()
                }
                .buttonStyle(.link)
            }
        }
        .padding()
        .frame(maxWidth: 560, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .contain)
    }
}
