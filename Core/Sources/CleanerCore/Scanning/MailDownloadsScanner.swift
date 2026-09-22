import Foundation

/// Mail's Downloads/Attachments cache (§4, risk: medium — attachments the user opened
/// from Mail; review before deleting since the originals may live only on the server).
public struct MailDownloadsScanner: Scanner {
    public let name = "mail-downloads"
    public let supportedCategories: Set<JunkCategory> = [.mailDownloads]

    public init() {}

    static let folderNames = ["Mail Downloads", "Attachments"]

    public func scan(_ context: ScanContext) async -> ScannerResult {
        var result = ScannerResult()
        let container = context.library("Containers/com.apple.mail/Data/Library")
        guard context.fileManager.fileExists(atPath: container.path) else {
            return ScannerResult()
        }

        for folder in Self.folderNames {
            if Task.isCancelled { break }
            let root = container.appendingPathComponent(folder)
            guard context.fileManager.fileExists(atPath: root.path) else { continue }

            let (children, issues) = ScanSupport.contents(
                of: root, category: .mailDownloads, fileManager: context.fileManager
            )
            result.issues.append(contentsOf: issues)
            for child in children {
                let size = ScanSupport.size(of: child, fileManager: context.fileManager)
                result.items.append(
                    JunkItem(
                        path: child,
                        size: size,
                        category: .mailDownloads,
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
