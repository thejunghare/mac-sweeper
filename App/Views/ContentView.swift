import CleanerCore
import SwiftUI

/// Window chrome: a sidebar with three places — Clean, Storage, Deep Clean — and a detail
/// pane (§12.2). Each place puts its actions in the unified toolbar.
struct ContentView: View {
    @EnvironmentObject private var model: ScanViewModel
    @StateObject private var storage = StorageViewModel()
    @State private var destination: Destination? = .clean
    @State private var showConfirmation = false
    @State private var showPrivacy = false

    enum Destination: String, CaseIterable, Identifiable {
        case clean
        case storage
        case deepClean

        var id: String { rawValue }

        var title: String {
            switch self {
            case .clean: return "Clean"
            case .storage: return "Storage"
            case .deepClean: return "Deep Clean"
            }
        }

        var symbol: String {
            switch self {
            case .clean: return "sparkles"
            case .storage: return "internaldrive"
            case .deepClean: return "arrow.down.to.line"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        }
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
        List(selection: $destination) {
            ForEach(Destination.allCases) { destination in
                Label(destination.title, systemImage: destination.symbol)
                    // Must be the non-optional type: List(selection: Binding<Destination?>)
                    // matches rows tagged with `Destination`, not `Destination?`.
                    .tag(destination)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                showPrivacy = true
            } label: {
                Label("Privacy", systemImage: "lock.shield")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .accessibilityLabel("What Broom accesses and why")
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch destination ?? .clean {
        case .clean:
            switch model.phase {
            case .idle:
                WelcomeView()
            case .scanning:
                ScanProgressView()
            case .review:
                ReviewView { showConfirmation = true }
            case .cleaning:
                CleaningProgressView()
            case .finished:
                CleanSummaryView()
            }
        case .storage:
            StorageView()
                .environmentObject(storage)
        case .deepClean:
            DeepestFileView()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            switch destination ?? .clean {
            case .clean:
                cleanToolbar
            case .storage:
                Button {
                    storage.analyze()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(storage.isAnalyzing || storage.isDeleting)
                .help("Measure again")
            case .deepClean:
                if model.isFindingDeepestFile {
                    Button {
                        model.cancelDeepestFileSearch()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button {
                        Task { await model.findDeepestFile() }
                    } label: {
                        Label("Search Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isDeletingSuggestions)
                    .help("Search again")
                }
            }
        }
    }

    @ViewBuilder
    private var cleanToolbar: some View {
        switch model.phase {
        case .idle, .review, .finished:
            Button {
                Task { await model.startScan() }
            } label: {
                Label(model.phase == .idle ? "Scan" : "Scan Again", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Scan (⌘R)")
        case .scanning:
            Button {
                model.cancelScan()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .keyboardShortcut(.cancelAction)
            .help("Stop scanning")
        case .cleaning:
            Button {
                model.cancelClean()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .keyboardShortcut(.cancelAction)
            .help("Stop — moved items stay restorable")
        }
    }
}
