import Foundation

/// The scan categories supported by the app (§4 of PLAN.md).
///
/// Each case carries its default risk tier and whether items in the category are ever
/// eligible for in-app deletion. Informational categories (large files, duplicates) are
/// shown to the user but never deleted by the app — the user deletes those manually.
public enum JunkCategory: String, CaseIterable, Sendable, Codable, Identifiable {
    case userCaches
    case browserCaches
    case appLogs
    case systemLogs
    case trash
    case xcodeDerivedData
    case xcodeArchives
    case xcodeDeviceSupport
    case homebrewCache
    case mailDownloads
    case iosDeviceBackups
    case leftoverAppFiles
    case largeFiles
    case duplicates

    public var id: String { rawValue }

    /// Default risk tier for items in this category.
    public var riskLevel: RiskLevel {
        switch self {
        case .userCaches, .browserCaches, .appLogs, .trash, .homebrewCache, .xcodeDerivedData:
            return .low
        case .systemLogs, .xcodeArchives, .xcodeDeviceSupport,
             .mailDownloads, .leftoverAppFiles, .duplicates:
            return .medium
        case .iosDeviceBackups:
            return .high
        case .largeFiles:
            return .medium
        }
    }

    /// Whether the app may delete items of this category itself (via Trash).
    /// `false` means "informational only" — the UI must not offer deletion.
    public var isDeletable: Bool {
        switch self {
        case .largeFiles, .duplicates:
            return false
        default:
            return true
        }
    }

    /// Your own files (large files, duplicates): never preselected and never touched by
    /// the junk rules, but you may pick them yourself — `SafeDeleter` then applies the
    /// Storage screen's user-file checks (and keeps one copy of every duplicate).
    public var isUserChoice: Bool {
        self == .largeFiles || self == .duplicates
    }

    /// Whether an item can be selected for cleaning at all.
    public var canBeSelected: Bool { isDeletable || isUserChoice }

    public var displayName: String {
        switch self {
        case .userCaches: return "User Caches"
        case .browserCaches: return "Browser Caches"
        case .appLogs: return "App Logs"
        case .systemLogs: return "System Logs"
        case .trash: return "Trash"
        case .xcodeDerivedData: return "Xcode DerivedData"
        case .xcodeArchives: return "Xcode Archives"
        case .xcodeDeviceSupport: return "Xcode Device Support"
        case .homebrewCache: return "Homebrew Cache"
        case .mailDownloads: return "Mail Downloads"
        case .iosDeviceBackups: return "iOS Device Backups"
        case .leftoverAppFiles: return "Leftover App Files"
        case .largeFiles: return "Large Files"
        case .duplicates: return "Duplicate Files"
        }
    }

    /// SF Symbol used in the sidebar and result rows.
    public var symbolName: String {
        switch self {
        case .userCaches: return "shippingbox"
        case .browserCaches: return "safari"
        case .appLogs: return "doc.text"
        case .systemLogs: return "waveform.path.ecg"
        case .trash: return "trash"
        case .xcodeDerivedData: return "hammer"
        case .xcodeArchives: return "archivebox"
        case .xcodeDeviceSupport: return "cable.connector"
        case .homebrewCache: return "mug"
        case .mailDownloads: return "envelope"
        case .iosDeviceBackups: return "iphone"
        case .leftoverAppFiles: return "app.badge"
        case .largeFiles: return "arrow.up.right.square"
        case .duplicates: return "doc.on.doc"
        }
    }

    /// Human-readable explanation of what this category contains and why it is (or isn't)
    /// safe to delete. Surfaced in the "What does this app access and why" screen (§5.8).
    public var explanation: String {
        switch self {
        case .userCaches:
            return "Temporary files apps keep in ~/Library/Caches to speed things up. Safe to delete — apps rebuild them automatically."
        case .browserCaches:
            return "Cached page assets for Safari, Chrome and Firefox. Sites will reload their assets once after cleaning."
        case .appLogs:
            return "Diagnostic logs apps write to ~/Library/Logs. Apps recreate these as needed."
        case .systemLogs:
            return "Diagnostic reports in /Library/Logs/DiagnosticReports. Old reports are safe to remove; the OS writes new ones."
        case .trash:
            return "Items you already deleted. Emptying these reclaims space permanently — review the list carefully."
        case .xcodeDerivedData:
            return "Xcode build intermediates and indexes. Always safe to delete — the next build regenerates them (slower first build)."
        case .xcodeArchives:
            return "Archived builds of your apps, used for App Store submissions and symbolication. Delete only archives you no longer need."
        case .xcodeDeviceSupport:
            return "Symbol files downloaded from connected devices for debugging. Xcode re-downloads them when a device reconnects."
        case .homebrewCache:
            return "Downloaded Homebrew package archives. Safe to delete — brew re-downloads on demand."
        case .mailDownloads:
            return "Attachments you opened from Mail's Downloads folder. Review carefully — some may not exist elsewhere."
        case .iosDeviceBackups:
            return "Full backups of iPhone/iPad made by Finder or iTunes. Deleting one is permanent if it's your only backup — confirm carefully."
        case .leftoverAppFiles:
            return "Preferences, caches and support files whose owning app is no longer installed. Only exact bundle-identifier matches are reported."
        case .largeFiles:
            return "Files over the size threshold in your home folder. Never preselected — pick the ones you no longer need."
        case .duplicates:
            return "Files with identical content (SHA-256, computed locally). Broom always keeps at least one copy."
        }
    }
}
