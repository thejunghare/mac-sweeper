import CleanerCore
import SwiftUI

/// Permanent, visible "What does this app access and why" screen (§5.1, §5.5, §5.8).
/// Doubles as the in-app privacy policy content.
struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    private let categories = JunkCategory.allCases

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("What Broom Accesses and Why", systemImage: "lock.shield")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .padding()
            .glassBar()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    principle(
                        title: "Your data never leaves this Mac",
                        body: """
                            Broom never uploads file names, paths, sizes, or contents. \
                            Duplicate detection hashes files locally with SHA-256 and \
                            discards them after comparison. There is no analytics, no \
                            telemetry, and no background phone-home.
                            """
                    )

                    principle(
                        title: "Reads metadata, writes only with your confirmation",
                        body: """
                            Scanning reads names, sizes and modification dates. Deletion \
                            happens only after you review the list and confirm — and it \
                            always uses the Trash, never permanent deletion. The Trash is \
                            never emptied automatically.
                            """
                    )

                    principle(
                        title: "Deepest File lookup",
                        body: """
                            Only when you open it, Broom walks your home folder reading file \
                            names and depth (never contents) to find the most deeply nested \
                            file, and tells you whether its safety rules would allow deleting \
                            it. Nothing is deleted from that screen.
                            """
                    )

                    principle(
                        title: "Full Disk Access",
                        body: FullDiskAccess.explanation + "\n\nBroom asks for this only when you choose to scan protected locations, and links you straight to the relevant System Settings pane."
                    )

                    principle(
                        title: "Protected locations are never touched",
                        body: """
                            A hard denylist blocks /System, /bin, /sbin, /usr, \
                            /Library/Extensions and your Desktop/Documents/Pictures/Movies \
                            from ever being deleted, no matter what any scanner reports. \
                            SIP is never circumvented.
                            """
                    )

                    Text("Scan categories")
                        .font(.headline)
                        .padding(.top, 6)

                    ForEach(categories) { category in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: category.symbolName)
                                .frame(width: 22)
                                .foregroundStyle(riskColor(category.riskLevel))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(category.displayName)
                                        .font(.callout.weight(.medium))
                                    RiskBadge(risk: category.riskLevel)
                                    if !category.isDeletable {
                                        Text("informational only")
                                            .font(.caption2)
                                            .italic()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(category.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Text("No warranty. Always review before cleaning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .glassBar()
        }
        .frame(width: 620, height: 640)
    }

    private func principle(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
