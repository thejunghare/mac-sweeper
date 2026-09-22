import Foundation

/// Direct children of `~/.Trash` (§4, risk: low — the user already deleted these).
public struct TrashScanner: Scanner {
    public let name = "trash"
    public let supportedCategories: Set<JunkCategory> = [.trash]

    public init() {}

    public func scan(_ context: ScanContext) async -> ScannerResult {
        let root = context.homeDirectory.appendingPathComponent(".Trash")
        guard context.fileManager.fileExists(atPath: root.path) else { return ScannerResult() }

        var result = ScannerResult()
        let (children, issues) = ScanSupport.contents(
            of: root, category: .trash, fileManager: context.fileManager
        )
        result.issues = issues

        for child in children {
            if Task.isCancelled { break }
            let size = ScanSupport.size(of: child, fileManager: context.fileManager)
            result.items.append(
                JunkItem(
                    path: child,
                    size: size,
                    category: .trash,
                    riskLevel: .low,
                    modificationDate: ScanSupport.modificationDate(of: child),
                    root: root
                )
            )
        }
        return result
    }
}
