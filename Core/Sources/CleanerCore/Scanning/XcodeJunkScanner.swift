import Foundation

/// Xcode-derived junk (§4):
/// - `DerivedData` (low risk — regenerated on every build),
/// - `Archives` (medium — needed for submissions/symbolication; user reviews each),
/// - `* Device Support` (medium — re-downloaded when a device reconnects).
public struct XcodeJunkScanner: Scanner {
    public let name = "xcode-junk"
    public let supportedCategories: Set<JunkCategory> = [
        .xcodeDerivedData, .xcodeArchives, .xcodeDeviceSupport
    ]

    public init() {}

    public func scan(_ context: ScanContext) async -> ScannerResult {
        var result = ScannerResult()
        let developerDir = context.library("Developer/Xcode")
        guard context.fileManager.fileExists(atPath: developerDir.path) else {
            return ScannerResult()
        }

        let targets: [(relative: String, category: JunkCategory, risk: RiskLevel)] = [
            ("DerivedData", .xcodeDerivedData, .low),
            ("Archives", .xcodeArchives, .medium),
            ("iOS DeviceSupport", .xcodeDeviceSupport, .medium),
            ("watchOS DeviceSupport", .xcodeDeviceSupport, .medium),
            ("tvOS DeviceSupport", .xcodeDeviceSupport, .medium),
            ("UserData/Previews", .xcodeDerivedData, .low),
        ]

        for target in targets {
            if Task.isCancelled { break }
            let root = developerDir.appendingPathComponent(target.relative)
            guard context.fileManager.fileExists(atPath: root.path) else { continue }

            let (children, issues) = ScanSupport.contents(
                of: root, category: target.category, fileManager: context.fileManager
            )
            result.issues.append(contentsOf: issues)

            // Archives are reviewed as individual .xcarchive bundles inside one root;
            // DeviceSupport items are per-device symbol sets.
            for child in children {
                guard !context.configuration.isExcluded(path: child.path) else { continue }
                let size = ScanSupport.size(of: child, fileManager: context.fileManager)
                result.items.append(
                    JunkItem(
                        path: child,
                        size: size,
                        category: target.category,
                        riskLevel: target.risk,
                        modificationDate: ScanSupport.modificationDate(of: child),
                        root: root
                    )
                )
            }
        }
        return result
    }
}
