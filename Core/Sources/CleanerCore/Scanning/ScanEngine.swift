import Foundation

/// Runs all enabled scanners concurrently (structured concurrency, §2), then:
/// 1. deduplicates overlapping paths (specific scanners beat generic sweeps),
/// 2. filters every result through the rules engine — a scanner bug can never surface a
///    denylisted or out-of-root path as "deletable" (§5.2, §9),
/// 3. computes the effective risk level per item.
///
/// The engine itself is read-only and fully cancellable.
public actor ScanEngine {
    private let scanners: [any Scanner]
    private let rules: RulesEngine
    private let logger: CoreLogging

    public init(
        scanners: [any Scanner] = ScannerRegistry.defaultScanners(),
        rules: RulesEngine = RulesEngine(),
        logger: CoreLogging = .shared
    ) {
        self.scanners = scanners
        self.rules = rules
        self.logger = logger
    }

    /// Progress callback, invoked on the caller's actor context for each scanner finish.
    public struct Progress: Sendable {
        public var completedScanners: Int
        public var totalScanners: Int
        public var latestItems: [JunkItem]

        public init(completedScanners: Int, totalScanners: Int, latestItems: [JunkItem]) {
            self.completedScanners = completedScanners
            self.totalScanners = totalScanners
            self.latestItems = latestItems
        }

        public var fractionCompleted: Double {
            totalScanners == 0 ? 1 : Double(completedScanners) / Double(totalScanners)
        }
    }

    @discardableResult
    public func scan(
        configuration: ScanConfiguration = ScanConfiguration(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async -> ScanReport {
        let startedAt = Date()
        let context = ScanContext(
            homeDirectory: homeDirectory,
            configuration: configuration
        )

        let enabled = scanners.filter { scanner in
            scanner.supportedCategories.isDisjoint(with: configuration.enabledCategories) == false
        }

        let results = await withTaskGroup(of: (any Scanner, ScannerResult).self) { group -> [(any Scanner, ScannerResult)] in
            for scanner in enabled {
                group.addTask {
                    let result = await scanner.scan(context)
                    return (scanner, result)
                }
            }
            var collected: [(any Scanner, ScannerResult)] = []
            var completed = 0
            for await (scanner, result) in group {
                collected.append((scanner, result))
                completed += 1
                progress?(Progress(
                    completedScanners: completed,
                    totalScanners: enabled.count,
                    latestItems: result.items
                ))
                try? Task.checkCancellation()
            }
            return collected
        }

        // Stable order: registry order defines scanner precedence for dedup.
        let precedenceIndex: [String: Int] = Dictionary(
            uniqueKeysWithValues: scanners.enumerated().map { ($1.name, $0) }
        )
        let ordered = results.sorted {
            (precedenceIndex[$0.0.name] ?? .max) < (precedenceIndex[$1.0.name] ?? .max)
        }

        // Dedup by path: keep the item from the highest-precedence scanner.
        var bestByPath: [String: JunkItem] = [:]
        var specificity: [JunkCategory: Int] = [:]
        var issues: [ScanIssue] = []
        var seenIssueKeys: Set<String> = []

        for (_, result) in ordered {
            for (category, value) in result.categorySpecificity {
                specificity[category] = min(specificity[category] ?? .max, value)
            }
            issues.append(contentsOf: result.issues.filter { issue in
                let key = issue.path.path + issue.reason.rawValue
                return seenIssueKeys.insert(key).inserted
            })
            for item in result.items {
                guard configuration.enabledCategories.contains(item.category) else { continue }
                guard !configuration.isExcluded(path: item.path.path) else { continue }
                let key = item.path.path
                if bestByPath[key] == nil {
                    bestByPath[key] = item
                }
            }
        }

        // Rules engine pass — the safety net (§9: test the net itself).
        var accepted: [JunkItem] = []
        for item in bestByPath.values {
            let verdict = rules.validate(item)
            switch verdict {
            case .allow(let effectiveRisk):
                accepted.append(
                    JunkItem(
                        path: item.path,
                        size: item.size,
                        category: item.category,
                        riskLevel: max(effectiveRisk, item.riskLevel),
                        modificationDate: item.modificationDate,
                        root: item.root,
                        detail: item.detail
                    )
                )
            case .deny(let reason):
                logger.warning("Rules engine rejected \(item.path.path): \(reason)")
            }
        }

        // Informational categories are kept but marked with their canonical risk.
        let sorted = accepted.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                return lhs.category.rawValue < rhs.category.rawValue
            }
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.path.path < rhs.path.path
        }

        let finishedAt = Date()
        logger.info(
            "Scan finished in \(String(format: "%.2f", finishedAt.timeIntervalSince(startedAt)))s: " +
            "\(sorted.count) items, \(ByteFormat.string(sorted.reduce(0) { $0 + $1.size })) found"
        )
        return ScanReport(items: sorted, issues: issues, startedAt: startedAt, finishedAt: finishedAt)
    }
}

/// Canonical scanner set, in precedence order (specific before generic).
public enum ScannerRegistry {
    public static func defaultScanners() -> [any Scanner] {
        [
            BrowserCachesScanner(),
            HomebrewCacheScanner(),
            MailDownloadsScanner(),
            XcodeJunkScanner(),
            MobileSyncBackupsScanner(),
            LeftoverAppFilesScanner(),
            UserCachesScanner(),
            AppLogsScanner(),
            SystemLogsScanner(),
            TrashScanner(),
            LargeFilesScanner(),
            DuplicatesScanner(),
        ]
    }
}
