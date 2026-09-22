import Foundation

/// Sweeps direct children of `~/Library/Caches` (§4, risk: low).
/// Browser/Homebrew caches are claimed by their more specific scanners first via
/// registry precedence dedup in `ScanEngine`.
public struct UserCachesScanner: Scanner {
    public let name = "user-caches"
    public let supportedCategories: Set<JunkCategory> = [.userCaches]

    public init() {}

    public func scan(_ context: ScanContext) async -> ScannerResult {
        let root = context.library("Caches")
        guard context.fileManager.fileExists(atPath: root.path) else { return ScannerResult() }

        var result = ScannerResult()
        let (children, issues) = ScanSupport.contents(
            of: root, category: .userCaches, fileManager: context.fileManager
        )
        result.issues = issues

        for child in children {
            if Task.isCancelled { break }
            guard !context.configuration.isExcluded(path: child.path) else { continue }
            let size = ScanSupport.size(of: child, fileManager: context.fileManager)
            result.items.append(
                JunkItem(
                    path: child,
                    size: size,
                    category: .userCaches,
                    riskLevel: .low,
                    modificationDate: ScanSupport.modificationDate(of: child),
                    root: root
                )
            )
        }
        return result
    }
}
