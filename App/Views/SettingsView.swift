import CleanerCore
import SwiftUI

/// Settings scene, current tabbed style (§12.2).
struct SettingsView: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            categoriesTab
                .tabItem { Label("Categories", systemImage: "list.bullet.rectangle") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(12)
    }

    private var generalTab: some View {
        Form {
            Section {
                Stepper(value: $model.largeFileMinimumMB, in: 100...10_000, step: 100) {
                    HStack {
                        Text("Large-file threshold")
                        Spacer()
                        Text("\(model.largeFileMinimumMB) MB")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityLabel("Large file threshold, \(model.largeFileMinimumMB) megabytes")

                Text("Applies to the informational Large Files list. Broom never deletes large files itself — you review them and delete in Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Full Disk Access") {
                    if model.hasFullDiskAccess {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open Settings…") {
                            model.openFullDiskAccessSettings()
                        }
                        .buttonStyle(.link)
                    }
                }
                Button("Re-check now") { model.refreshFullDiskAccess() }
                    .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
    }

    private var categoriesTab: some View {
        Form {
            Section {
                ForEach(JunkCategory.allCases) { category in
                    Toggle(isOn: binding(for: category)) {
                        HStack {
                            Image(systemName: category.symbolName)
                                .frame(width: 22)
                                .foregroundStyle(riskColor(category.riskLevel))
                            VStack(alignment: .leading) {
                                Text(category.displayName)
                                Text(category.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .accessibilityLabel("\(category.displayName) scan category")
                }
            } footer: {
                Text("Disabling a category excludes it from the next scan. High-risk categories always require an extra typed confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "broom")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Broom")
                .font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("""
                Broom finds and safely removes junk files on this Mac. It shows you \
                everything before touching anything, deletes only to the Trash, and never \
                sends your data anywhere. Provided without any warranty; you review every clean.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Link("Privacy & access details", destination: URL(string: "https://example.invalid/broom/privacy")!)
                .font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 20)
    }

    private func binding(for category: JunkCategory) -> Binding<Bool> {
        Binding(
            get: { model.enabledCategories.contains(category) },
            set: { enabled in
                if enabled {
                    model.enabledCategories.insert(category)
                } else {
                    model.enabledCategories.remove(category)
                }
            }
        )
    }
}
