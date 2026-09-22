import Foundation

/// Finds files over a size threshold in the user's folders (§4, INFORMATIONAL ONLY —
/// `isDeletable == false`; the app never deletes these, the user does it in Finder).
public struct LargeFilesScanner: Scanner {
    public let name = "large-files"
    public let supportedCategories: Set<JunkCategory> = [.largeFiles]

    public init() {}

    public func scan(_ context: ScanContext) async -> ScannerResult {
        collect(context)
    }

    // Directory enumeration is synchronous by nature; keeping it out of the async context
    // avoids Swift 6's non-Sendable-iterator restriction.
    private func collect(_ context: ScanContext) -> ScannerResult {
        let config = context.configuration
        let root = context.homeDirectory
        let libraryURL = context.homeDirectory.appendingPathComponent("Library")
        let trashURL = context.homeDirectory.appendingPathComponent(".Trash")

        var result = ScannerResult()
        guard let enumerator = context.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isPackageKey, .isSymbolicLinkKey],
            options: [], // no .followsSymlinks — never traverse links
            errorHandler: { _, _ in true }
        ) else { return result }

        var found: [JunkItem] = []

        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            if found.count >= config.largeFileResultLimit { break }

            let path = url.path
            if path == libraryURL.path && !config.largeFilesIncludeLibrary {
                enumerator.skipDescendants()
                continue
            }
            if path == trashURL.path {
                enumerator.skipDescendants()
                continue
            }
            if config.isExcluded(path: path) {
                enumerator.skipDescendants()
                continue
            }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isPackageKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }

            if values?.isPackage == true {
                // Count the bundle as a whole; don't descend into its contents.
                enumerator.skipDescendants()
                let size = Int64(values?.fileSize ?? 0)
                if size >= config.largeFileMinimumSize {
                    found.append(makeItem(url: url, size: size, root: root))
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }
            let size = Int64(values?.fileSize ?? 0)
            if size >= config.largeFileMinimumSize {
                found.append(makeItem(url: url, size: size, root: root))
            }
        }

        result.items = found.sorted { $0.size > $1.size }
        return result
    }

    private func makeItem(url: URL, size: Int64, root: URL) -> JunkItem {
        JunkItem(
            path: url,
            size: size,
            category: .largeFiles,
            riskLevel: .medium,
            modificationDate: ScanSupport.modificationDate(of: url),
            root: root
        )
    }
}
