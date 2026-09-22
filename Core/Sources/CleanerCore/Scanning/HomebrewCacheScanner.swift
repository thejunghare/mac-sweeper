import Foundation

/// Homebrew download cache: `~/Library/Caches/Homebrew` and `~/.cache/Homebrew`
/// (§4, risk: low). Registered before `UserCachesScanner` for correct labelling.
public struct HomebrewCacheScanner: Scanner {
    public let name = "homebrew-cache"
    public let supportedCategories: Set<JunkCategory> = [.homebrewCache]

    public init() {}

    public func scan(_ context: ScanContext) async -> ScannerResult {
        var result = ScannerResult()
        let roots = [
            context.library("Caches/Homebrew"),
            context.homeDirectory.appendingPathComponent(".cache/Homebrew"),
        ]

        for root in roots {
            if Task.isCancelled { break }
            guard context.fileManager.fileExists(atPath: root.path) else { continue }
            let (children, issues) = ScanSupport.contents(
                of: root, category: .homebrewCache, fileManager: context.fileManager
            )
            result.issues.append(contentsOf: issues)
            for child in children {
                guard !context.configuration.isExcluded(path: child.path) else { continue }
                let size = ScanSupport.size(of: child, fileManager: context.fileManager)
                result.items.append(
                    JunkItem(
                        path: child,
                        size: size,
                        category: .homebrewCache,
                        riskLevel: .low,
                        modificationDate: ScanSupport.modificationDate(of: child),
                        root: root
                    )
                )
            }
        }
        return result
    }
}
