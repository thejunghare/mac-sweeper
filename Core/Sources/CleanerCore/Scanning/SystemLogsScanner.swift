import Foundation

/// System diagnostic reports (§4, risk: medium — lives outside home; reading may need
/// FDA and deleting may fail without elevation — failures are reported, never forced).
public struct SystemLogsScanner: Scanner {
    public let name = "system-logs"
    public let supportedCategories: Set<JunkCategory> = [.systemLogs]

    public init() {}

    static let roots = [
        "/Library/Logs/DiagnosticReports",
        "/Library/Logs/CrashReporter",
    ]

    public func scan(_ context: ScanContext) async -> ScannerResult {
        var result = ScannerResult()

        for path in Self.roots {
            if Task.isCancelled { break }
            let root = URL(fileURLWithPath: path)
            guard context.fileManager.fileExists(atPath: root.path) else { continue }
            let (children, issues) = ScanSupport.contents(
                of: root, category: .systemLogs, fileManager: context.fileManager
            )
            result.issues.append(contentsOf: issues)
            for child in children {
                guard !context.configuration.isExcluded(path: child.path) else { continue }
                let size = ScanSupport.size(of: child, fileManager: context.fileManager)
                result.items.append(
                    JunkItem(
                        path: child,
                        size: size,
                        category: .systemLogs,
                        riskLevel: .medium,
                        modificationDate: ScanSupport.modificationDate(of: child),
                        root: root
                    )
                )
            }
        }
        return result
    }
}
