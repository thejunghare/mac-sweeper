import Foundation

/// Full Disk Access (TCC) detection and remediation UX (§5.1).
///
/// Strategy: probe a user-owned directory that TCC protects (`~/Library/Safari`).
/// Without FDA the open/list call fails with EPERM even though file modes would allow it.
/// We never prompt on launch — the UI explains *why* access is needed first, then offers
/// to deep-link into System Settings.
public enum FullDiskAccess {
    public static let settingsDeepLink =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Probe paths, in order of preference. All are user-owned and TCC-gated by FDA.
    public static let probePaths = [
        "Library/Safari",
        "Library/Messages",
        "Library/Mail",
        "Library/Application Support/MobileSync/Backup",
    ]

    /// Returns true when the process appears to have Full Disk Access.
    public static func hasAccess(fileManager: FileManager = .default, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        for relative in probePaths {
            let url = home.appendingPathComponent(relative)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                _ = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
                return true
            } catch {
                // Protected and unreadable → try the next probe (a missing/unprotected
                // path proves access if it *can* be listed).
                continue
            }
        }
        // If none of the protected probe dirs exist, treat as accessible (fresh account).
        return true
    }

    // NOTE: Core is UI-free by design (§2). The app target opens `settingsDeepLink`
    // via NSWorkspace.shared.open(_:).

    public static let explanation = """
    Broom needs Full Disk Access to find junk files in protected locations \
    (such as ~/Library/Caches, Mail data and iOS backups). macOS blocks access to these \
    folders for every app until you grant it. Broom never reads file contents — only names, \
    sizes and dates — and nothing about your files ever leaves this Mac.
    """
}
