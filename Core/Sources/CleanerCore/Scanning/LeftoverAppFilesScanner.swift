import Foundation

/// Detects leftover files of *uninstalled* apps (§4, risk: medium).
///
/// Conservative by design — only exact reverse-DNS bundle-identifier matches are
/// reported, and only from well-known Library subfolders:
/// - `Preferences/<bundle-id>.plist`
/// - `Saved Application State/<bundle-id>.savedState`
/// - `Containers/<bundle-id>`
/// - `Caches/<bundle-id>` (and `<bundle-id>-suffix` caches)
///
/// `com.apple.*` identifiers are never considered leftovers (system components get
/// updated, not "uninstalled"). `Application Support` folder names are *not* guessed at
/// because they rarely equal bundle IDs — guessing is how cleaners delete live data.
public struct LeftoverAppFilesScanner: Scanner {
    public let name = "leftover-app-files"
    public let supportedCategories: Set<JunkCategory> = [.leftoverAppFiles]

    /// Only report leftovers untouched for at least this long (avoids flags for apps
    /// being reinstalled/updated right now).
    public let minimumAge: TimeInterval

    /// App-bundle search roots; injectable so tests never read the real /Applications.
    public let appSearchRoots: [String]

public init(
        minimumAge: TimeInterval = 60 * 60 * 24 * 30,
        appSearchRoots: [String] = InstalledBundleIDs.standardRoots
    ) {
        self.minimumAge = minimumAge
        self.appSearchRoots = appSearchRoots
    }

    public func scan(_ context: ScanContext) async -> ScannerResult {
        var result = ScannerResult()
        let installed = InstalledBundleIDs.collect(
            fileManager: context.fileManager, roots: appSearchRoots
        )
        guard !installed.isEmpty else { return result }

        let now = Date()
        let candidates: [(root: String, suffix: String?, category: JunkCategory)] = [
            ("Preferences", ".plist", .leftoverAppFiles),
            ("Saved Application State", ".savedState", .leftoverAppFiles),
            ("Containers", nil, .leftoverAppFiles),
            ("Caches", nil, .leftoverAppFiles),
        ]

        for candidate in candidates {
            if Task.isCancelled { break }
            let root = context.library(candidate.root)
            guard context.fileManager.fileExists(atPath: root.path) else { continue }

            let (children, issues) = ScanSupport.contents(
                of: root, category: .leftoverAppFiles, fileManager: context.fileManager
            )
            result.issues.append(contentsOf: issues)

            for child in children {
                guard !context.configuration.isExcluded(path: child.path) else { continue }
                let stem = child.lastPathComponent
                guard let bundleID = Self.bundleID(
                    fromEntryName: stem, suffix: candidate.suffix
                ) else { continue }
                guard !bundleID.hasPrefix("com.apple.") else { continue }
                guard !installed.contains(bundleID) else { continue }
                guard let modified = ScanSupport.modificationDate(of: child),
                      now.timeIntervalSince(modified) >= minimumAge else { continue }

                let size = ScanSupport.size(of: child, fileManager: context.fileManager)
                result.items.append(
                    JunkItem(
                        path: child,
                        size: size,
                        category: .leftoverAppFiles,
                        riskLevel: .medium,
                        modificationDate: modified,
                        root: root,
                        detail: "No installed app owns “\(bundleID)”"
                    )
                )
            }
        }
        return result
    }

    static func bundleID(fromEntryName name: String, suffix: String?) -> String? {
        var stem = name
        if let suffix, stem.hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
        }
        // Reverse-DNS heuristic: at least two dots, no spaces.
        guard stem.contains("."), !stem.contains(" ") else { return nil }
        let parts = stem.split(separator: ".")
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return stem
    }
}

/// Bundle identifiers of apps installed in the standard locations.
public enum InstalledBundleIDs {
    public static let standardRoots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    public static func collect(fileManager: FileManager, roots: [String] = standardRoots) -> Set<String> {
        let searchRoots = roots

        var ids: Set<String> = []
        for root in searchRoots {
            guard let children = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for child in children where child.hasSuffix(".app") {
                let appURL = URL(fileURLWithPath: root).appendingPathComponent(child)
                let infoPlist = appURL.appendingPathComponent("Contents/Info.plist")
                if let dict = NSDictionary(contentsOf: infoPlist),
                   let bundleID = dict["CFBundleIdentifier"] as? String {
                    ids.insert(bundleID)
                }
            }
        }
        // Also consider bundle IDs of apps that ship inside Xcode/other locations? Not in
        // v1 — conservative false negatives are acceptable; false positives are not.
        return ids
    }
}
