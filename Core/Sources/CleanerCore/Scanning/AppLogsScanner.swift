import Foundation

/// Direct children of `~/Library/Logs` (§4, risk: low).
public struct AppLogsScanner: Scanner {
    public let name = "app-logs"
    public let supportedCategories: Set<JunkCategory> = [.appLogs]

    public init() {}

    public func scan(_ context: ScanContext) async -> ScannerResult {
        let root = context.library("Logs")
        guard context.fileManager.fileExists(atPath: root.path) else { return ScannerResult() }

        var result = ScannerResult()
        let (children, issues) = ScanSupport.contents(
            of: root, category: .appLogs, fileManager: context.fileManager
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
                    category: .appLogs,
                    riskLevel: .low,
                    modificationDate: ScanSupport.modificationDate(of: child),
                    root: root
                )
            )
        }
        return result
    }
}
