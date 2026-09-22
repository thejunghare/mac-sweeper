import XCTest
@testable import CleanerCore

final class ScanEngineTests: XCTestCase {

    /// The engine must dedupe overlapping paths so Homebrew/Browser caches are not
    /// double-counted by the generic caches sweep, and must run the rules engine over
    /// every scanner result.
    func testEngineDeduplicatesOverlappingScanners() async throws {
        let home = try FixtureTree.makeHomeLayout()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let engine = ScanEngine(rules: RulesEngine(homeDirectory: home.root))
        let report = await engine.scan(homeDirectory: home.root)

        let paths = report.items.map(\.path.path)
        XCTAssertEqual(Set(paths).count, paths.count, "duplicate paths in report")

        // Homebrew cache claimed by the specific scanner, not generic userCaches.
        let brew = report.items.first { $0.path.lastPathComponent == "Downloads"
            && $0.path.path.contains("Homebrew") }
        XCTAssertEqual(brew?.category, .homebrewCache)

        let safari = report.items.first { $0.path.path.contains("com.apple.Safari") }
        XCTAssertEqual(safari?.category, .browserCaches)
    }

    func testEngineFiltersDenylistedScannerOutput() async throws {
        let home = try FixtureTree.makeHomeLayout()
        defer { try? FileManager.default.removeItem(at: home.root) }

        // A deliberately buggy scanner that reports a /System path.
        struct BuggyScanner: CleanerCore.Scanner {
            let name = "buggy"
            let supportedCategories: Set<JunkCategory> = [.userCaches]
            func scan(_ context: ScanContext) async -> ScannerResult {
                ScannerResult(items: [
                    JunkItem(path: URL(fileURLWithPath: "/System/Library/Important"),
                             size: 1, category: .userCaches, riskLevel: .low,
                             root: URL(fileURLWithPath: "/System")),
                ])
            }
        }

        let engine = ScanEngine(
            scanners: [BuggyScanner()],
            rules: RulesEngine(homeDirectory: home.root)
        )
        let report = await engine.scan(homeDirectory: home.root)
        XCTAssertTrue(report.items.isEmpty, "denylisted scanner output must be filtered out")
    }

    func testEngineHonorsCategoryConfiguration() async throws {
        let home = try FixtureTree.makeHomeLayout()
        defer { try? FileManager.default.removeItem(at: home.root) }

        var config = ScanConfiguration()
        config.enabledCategories = [.appLogs]

        let engine = ScanEngine(rules: RulesEngine(homeDirectory: home.root))
        let report = await engine.scan(configuration: config, homeDirectory: home.root)
        XCTAssertTrue(report.items.allSatisfy { $0.category == .appLogs })
        XCTAssertFalse(report.items.isEmpty)
    }

    func testReportTotalsAndGrouping() async throws {
        let home = try FixtureTree.makeHomeLayout()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let engine = ScanEngine(rules: RulesEngine(homeDirectory: home.root))
        let report = await engine.scan(homeDirectory: home.root)

        XCTAssertGreaterThan(report.totalSize, 0)
        XCTAssertGreaterThan(report.categories.count, 1)
        XCTAssertEqual(report.size(in: .appLogs),
                       report.items(in: .appLogs).reduce(0) { $0 + $1.size })
        XCTAssertGreaterThan(report.totalDeletableSize, 0)
    }

    func testExcludedPathsAreHonored() async throws {
        let home = try FixtureTree.makeHomeLayout()
        defer { try? FileManager.default.removeItem(at: home.root) }

        var config = ScanConfiguration()
        let excluded = home.url("Library/Caches/com.example.junkcache").path
        config.excludedPaths = [excluded]

        let engine = ScanEngine(rules: RulesEngine(homeDirectory: home.root))
        let report = await engine.scan(configuration: config, homeDirectory: home.root)
        XCTAssertFalse(report.items.contains { $0.path.path == excluded })
    }

    func testProgressCallbackCompletes() async throws {
        let home = try FixtureTree.makeHomeLayout()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let recorder = ProgressRecorder<Int>()
        let engine = ScanEngine(rules: RulesEngine(homeDirectory: home.root))
        let report = await engine.scan(homeDirectory: home.root) { progress in
            recorder.record(progress.completedScanners)
        }
        let values = recorder.values
        XCTAssertFalse(values.isEmpty)
        // Progress must count up from 1 without gaps to the number of enabled scanners.
        XCTAssertEqual(values, Array(1...values.count))
        XCTAssertGreaterThan(report.items.count, 0)
    }
}
