import Foundation

/// iOS device backups in `~/Library/Application Support/MobileSync/Backup` (§4, risk:
/// HIGH — potentially the user's only copy of phone data). Reported per device-backup
/// folder; the UI requires type-to-confirm for this category (§5.2).
public struct MobileSyncBackupsScanner: Scanner {
    public let name = "mobilesync-backups"
    public let supportedCategories: Set<JunkCategory> = [.iosDeviceBackups]

    public init() {}

    public func scan(_ context: ScanContext) async -> ScannerResult {
        let root = context.library("Application Support/MobileSync/Backup")
        guard context.fileManager.fileExists(atPath: root.path) else { return ScannerResult() }

        var result = ScannerResult()
        let (children, issues) = ScanSupport.contents(
            of: root, category: .iosDeviceBackups, fileManager: context.fileManager
        )
        result.issues = issues

        for child in children {
            if Task.isCancelled { break }
            let size = ScanSupport.size(of: child, fileManager: context.fileManager)
            result.items.append(
                JunkItem(
                    path: child,
                    size: size,
                    category: .iosDeviceBackups,
                    riskLevel: .high,
                    modificationDate: ScanSupport.modificationDate(of: child),
                    root: root,
                    detail: Self.deviceInfo(at: child)
                )
            )
        }
        return result
    }

    /// Best-effort friendly name + backup date from Info.plist inside the backup folder.
    static func deviceInfo(at backupURL: URL) -> String? {
        let infoPlist = backupURL.appendingPathComponent("Info.plist")
        guard let dict = NSDictionary(contentsOf: infoPlist) else { return nil }
        let deviceName = dict["Device Name"] as? String
        let productType = dict["Product Type"] as? String
        let dateString = dict["Date"] as? String ?? (dict["Last Modified"] as? String)

        var parts: [String] = []
        if let deviceName { parts.append(deviceName) }
        if let productType { parts.append(productType) }
        if let dateString { parts.append(dateString) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
