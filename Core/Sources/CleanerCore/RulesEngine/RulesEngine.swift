import Foundation

/// Path allow/deny rules — the heart of the safety model (§5.2).
///
/// Two layers:
/// 1. **Hard denylist**: system paths that can never be returned as deletable, regardless
///    of what a scanner claims. Defense in depth against scanner bugs.
/// 2. **Per-category allowlist**: every deletable item must fall inside one of the explicit
///    roots configured for its category. A scanner returning `~/Documents` as "caches"
///    is rejected.
///
/// Additionally, at *delete* time (not just scan time) `SymlinkGuard` re-verifies the
/// on-disk location of each item immediately before `trashItem` (TOCTOU protection).
public struct RulesEngine: Sendable {
    public let homeDirectory: URL

    public enum Verdict: Equatable, Sendable {
        case allow(RiskLevel)
        case deny(String)
    }

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    // MARK: Hard denylist — never deletable, never reported

    /// System locations that are never matched, in absolute standardized form.
    /// `/usr/local` is deliberately *not* carved out in v1: no v1 scanner targets it,
    /// and "cautious exceptions" are how denylists rot (§5.2).
    public var hardDenylist: [String] {
        [
            "/System",
            "/bin",
            "/sbin",
            "/usr",
            "/Library/Extensions",
            "/Library/ScriptingExtensions",
            "/private/var/db",
            "/private/var/root",
            "/private/etc",
            "/Applications", // the app never uninstalls apps by deleting bundles in v1
            "/Library/Apple",
            "/Library/Managed",
            "/usr/local",
        ]
    }

    /// Directories inside the home folder whose *contents* are the user's own documents.
    /// No scanner may produce deletable items here; informational categories
    /// (large files, duplicates) may reference them but are never deleted in-app.
    public var protectedHomeRoots: [String] {
        ["Desktop", "Documents", "Pictures", "Movies", "Music", "Public"].map {
            homeDirectory.appendingPathComponent($0).path
        }
    }

    // MARK: Per-category allowlist

    /// Explicit roots a category may produce items from. Items must be *strictly inside*
    /// one of these roots (the root itself is never a candidate).
    public func allowedRoots(for category: JunkCategory) -> [URL] {
        func lib(_ path: String) -> URL {
            homeDirectory.appendingPathComponent("Library").appendingPathComponent(path)
        }
        switch category {
        case .userCaches:
            return [lib("Caches")]
        case .browserCaches:
            // Specific cache directories inside ~/Library/Caches (plus browser profile caches).
            return [
                lib("Caches/com.apple.Safari"),
                lib("Caches/com.apple.Safari.SafeBrowsing"),
                lib("Caches/WebKit"),
                lib("Caches/Google/Chrome"),
                lib("Caches/Firefox"),
                lib("Caches/Mozilla"),
                lib("Containers/com.google.Chrome/Data/Service Worker"),
            ]
        case .appLogs:
            return [lib("Logs")]
        case .systemLogs:
            return [
                URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
                URL(fileURLWithPath: "/Library/Logs/CrashReporter"),
            ]
        case .trash:
            return [homeDirectory.appendingPathComponent(".Trash")]
        case .xcodeDerivedData:
            return [lib("Developer/Xcode/DerivedData")]
        case .xcodeArchives:
            return [lib("Developer/Xcode/Archives")]
        case .xcodeDeviceSupport:
            return [
                lib("Developer/Xcode/iOS DeviceSupport"),
                lib("Developer/Xcode/watchOS DeviceSupport"),
                lib("Developer/Xcode/tvOS DeviceSupport"),
            ]
        case .homebrewCache:
            return [
                lib("Caches/Homebrew"),
                homeDirectory.appendingPathComponent(".cache/Homebrew"),
                homeDirectory.appendingPathComponent(".brew"),
            ]
        case .mailDownloads:
            return [
                lib("Containers/com.apple.mail/Data/Library/Mail Downloads"),
                lib("Containers/com.apple.mail/Data/Library/Attachments"),
            ]
        case .iosDeviceBackups:
            return [lib("Application Support/MobileSync/Backup")]
        case .leftoverAppFiles:
            return [
                lib("Application Support"),
                lib("Preferences"),
                lib("Caches"),
                lib("Containers"),
                lib("Saved Application State"),
                lib("WebKit"),
            ]
        case .largeFiles, .duplicates:
            // Informational only — may reference any file under home, but `isDeletable`
            // is false, so these can never reach the deletion engine.
            return [homeDirectory]
        }
    }

    // MARK: Validation

    /// Scan-time validation: does this item plausibly belong where the scanner put it?
    public func validate(_ item: JunkItem) -> Verdict {
        let path = item.path.standardizedFileURL.path

        // Structural checks.
        guard path.hasPrefix("/") else { return .deny("relative path") }
        if path.contains("/../") || path.hasSuffix("/..") {
            return .deny("path traversal component")
        }

        // Hard denylist first — absolute, no exceptions.
        for denied in hardDenylist {
            if path == denied || path.hasPrefix(denied + "/") {
                return .deny("hard denylist: \(denied)")
            }
        }

        // Must be under home OR under an explicitly allowed system root for its category.
        let roots = allowedRoots(for: item.category)
        let homePath = homeDirectory.path
        let isUnderHome = path == homePath || path.hasPrefix(homePath + "/")
        let isUnderAllowedRoot = roots.contains { root in
            let rootPath = root.standardizedFileURL.path
            return path.hasPrefix(rootPath + "/") && path != rootPath
        }

        if !isUnderHome && !isUnderAllowedRoot {
            // System-root categories (system logs) are allowed via their explicit roots.
            return .deny("outside home and outside allowed roots for \(item.category.rawValue)")
        }
        if !isUnderAllowedRoot {
            return .deny("not inside an allowed root for \(item.category.rawValue)")
        }

        // Informational categories may live in protected home roots (Documents etc.).
        // Deletable categories never may.
        if item.category.isDeletable {
            for protected in protectedHomeRoots {
                if path == protected || path.hasPrefix(protected + "/") {
                    return .deny("protected user-data root")
                }
            }
        }

        return .allow(item.category.riskLevel)
    }

    /// Delete-time gate: everything from `validate`, plus the category must be deletable
    /// at all. Called immediately before every `trashItem`.
    public func mayDelete(_ item: JunkItem) -> Bool {
        guard item.category.isDeletable else { return false }
        if case .allow = validate(item) { return true }
        return false
    }
}
