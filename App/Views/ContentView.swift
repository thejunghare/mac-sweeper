import CleanerCore
import SwiftUI

/// Standard window chrome: sidebar of categories + detail pane (§12.2),
/// unified toolbar, Liquid Glass materials with pre-macOS-26 fallbacks (§12.1).
struct ContentView: View {
    @EnvironmentObject private var model: ScanViewModel
    @State private var selectedSidebarCategory: JunkCategory?
    @State private var showConfirmation = false
    @State private var showPrivacy = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            detail
        }
        .searchable(
            text: $model.searchText,
            placement: .toolbar,
            prompt: "Filter results"
        )
        .toolbar { toolbarContent }
        .sheet(isPresented: $showConfirmation) {
            CleanConfirmationSheet(
                onConfirm: {
                    showConfirmation = false
                    Task { await model.performClean() }
                },
                onCancel: { showConfirmation = false }
            )
        }
        .sheet(isPresented: $showPrivacy) {
            PrivacyView()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.phase)
        .onAppear { model.refreshFullDiskAccess() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selectedSidebarCategory) {
            Section {
                if model.report == nil {
                    Label("Overview", systemImage: "sparkles")
                        .tag(JunkCategory?.none)
                }
                ForEach(model.categoriesInReport) { category in
                    categoryRow(category)
                        .tag(category as JunkCategory?)
                }
            } header: {
                Text(model.report == nil ? "Broom" : "Found")
            }

            Section("Actions") {
                Button {
                    showPrivacy = true
                } label: {
                    Label("What Broom Accesses", systemImage: "lock.shield")
                }
                .accessibilityLabel("What Broom accesses and why")
            }
        }
        .listStyle(.sidebar)
    }

    private func categoryRow(_ category: JunkCategory) -> some View {
        let size = model.size(in: category)
        let count = model.items(in: category).count
        return HStack {
            Label(category.displayName, systemImage: category.symbolName)
            Spacer()
            if size > 0 {
                Text(ByteFormat.string(size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .badge(count)
        .accessibilityLabel("\(category.displayName), \(count) items, \(ByteFormat.string(size))")
    }

    // MARK: Detail

    private var detail: some View {
        Group {
            switch model.phase {
            case .idle:
                WelcomeView()
            case .scanning:
                ScanProgressView()
            case .review:
                ReviewView(selectedCategory: $selectedSidebarCategory)
            case .cleaning:
                CleaningProgressView()
            case .finished:
                CleanSummaryView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(surfaceBackground)
    }

    private var surfaceBackground: some View {
        // Vibrant material behind content; glass containers layer on top (§12.1).
        Rectangle()
            .fill(.background)
            .ignoresSafeArea()
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            switch model.phase {
            case .idle, .finished:
                Button {
                    Task { await model.startScan() }
                } label: {
                    Label(model.phase == .finished ? "Scan Again" : "Scan",
                          systemImage: "magnifyingglass")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
                .accessibilityLabel("Start scan")

            case .scanning:
                Button {
                    model.cancelScan()
                } label: {
                    Label("Cancel Scan", systemImage: "xmark.circle")
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel the running scan")

            case .review:
                Button {
                    model.selectAll(in: .userCaches, true)
                } label: {
                    Label("Select All", systemImage: "checkmark.circle")
                }
                .help("Select all low- and medium-risk items")

                Button {
                    showConfirmation = true
                } label: {
                    Label("Clean…", systemImage: "trash")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedCount == 0)
                .accessibilityLabel("Clean selected items")

            case .cleaning:
                Button {
                    model.cancelClean()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel the running clean")
            }
        }

        ToolbarItem(placement: .status) {
            if model.phase == .scanning || model.phase == .cleaning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 140)
            } else if let report = model.report, model.phase == .review {
                Text("\(ByteFormat.string(report.totalDeletableSize)) reclaimable")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("\(ByteFormat.string(report.totalDeletableSize)) reclaimable")
            }
        }
    }
}
