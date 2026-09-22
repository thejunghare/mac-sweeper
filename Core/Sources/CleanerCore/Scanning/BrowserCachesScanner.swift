import Foundation

/// Known browser cache locations (§4, risk: low). Registered *before* `UserCachesScanner`
/// so browser caches are labelled with their own category instead of generic "caches".
public struct BrowserCachesScanner: Scanner {
    public let name = "browser-caches"
    public let supportedCategories: Set<JunkCategory> = [.browserCaches]

    public init() {}

    /// Relative to ~/Library/Caches unless noted.
    static let cachePaths = [
        "com.apple.Safari",
        "com.apple.Safari.SafeBrowsing",
        "com.apple.Safari.ServiceWorker",
        "Google/Chrome",
        "Google/ChromeOS",
        "Firefox",
        "Mozilla",
    ]

    public func scan(_ context: ScanContext) async -> ScannerResult {
        var result = ScannerResult()
        let cachesRoot = context.library("Caches")

        var candidates: [(url: URL, root: URL)] = []
        for relative in Self.cachePaths {
            let url = cachesRoot.appendingPathComponent(relative)
            if context.fileManager.fileExists(atPath: url.path) {
                candidates.append((url, cachesRoot))
            }
        }
        // Chrome/Firefox service-worker caches inside containers (FDA-gated).
        let chromeServiceWorker = context.library(
            "Containers/com.google.Chrome/Data/Service Worker"
        )
        if context.fileManager.fileExists(atPath: chromeServiceWorker.path) {
            candidates.append((
                chromeServiceWorker,
                context.library("Containers/com.google.Chrome")
            ))
        }

        for candidate in candidates {
            if Task.isCancelled { break }
            let (children, issues) = ScanSupport.contents(
                of: candidate.url, category: .browserCaches, fileManager: context.fileManager
            )
            result.issues.append(contentsOf: issues)
            for child in children {
                guard !context.configuration.isExcluded(path: child.path) else { continue }
                let size = ScanSupport.size(of: child, fileManager: context.fileManager)
                result.items.append(
                    JunkItem(
                        path: child,
                        size: size,
                        category: .browserCaches,
                        riskLevel: .low,
                        modificationDate: ScanSupport.modificationDate(of: child),
                        root: candidate.root
                    )
                )
            }
        }
        return result
    }
}
