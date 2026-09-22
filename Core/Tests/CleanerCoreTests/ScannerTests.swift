import XCTest
@testable import CleanerCore

final class ScannerTests: XCTestCase {

    func testUserCachesScannerFindsOnlyCacheChildren() async throws {
        let home = try FixtureTree.makeHomeLayout()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let context = ScanContext(homeDirectory: home.root)
        let result = await UserCachesScanner().scan(context)

        let paths = Set(result.items.map { $0.path.lastPathComponent })
        XCTAssertEqual(paths, ["com.example.junkcache", "Homebrew", "com.apple.Safari"])
        XCTAssertTrue(result.items.allSatisfy { $0.category == .userCaches })
        XCTAssertTrue(result.items.allSatisfy { $0.root.path.hasSuffix("Library/Caches") })
    }

    func testAppLogsScannerFindsLogDirectories() async throws {
        let home = try FixtureTree.makeHomeLayout()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let result = await AppLogsScanner().scan(ScanContext(homeDirectory: home.root))
        XCTAssertEqual(result.items.map { $0.path.lastPathComponent }, ["com.example.app"])
        XCTAssertEqual(result.items.first?.category, .appLogs)
    }

    func testTrashScannerFindsTrashContents() async throws {
        let home = try FixtureTree.makeHomeLayout()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let result = await TrashScanner().scan(ScanContext(homeDirectory: home.root))
        XCTAssertEqual(result.items.map { $0.path.lastPathComponent }, ["old-document.pdf"])
        XCTAssertEqual(result.items.first?.root.lastPathComponent, ".Trash")
    }

    func testHomebrewAndBrowserScannersClaimTheirPaths() async throws {
        let home = try FixtureTree.makeHomeLayout()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let context = ScanContext(homeDirectory: home.root)

        let brew = await HomebrewCacheScanner().scan(context)
        XCTAssertEqual(brew.items.map { $0.path.lastPathComponent }, ["Downloads"])

        let browser = await BrowserCachesScanner().scan(context)
        XCTAssertEqual(browser.items.map { $0.path.lastPathComponent }, ["WebKitCache"])
        XCTAssertEqual(browser.items.first?.category, .browserCaches)
    }

    func testMissingDirectoriesProduceNoItemsAndNoIssues() async throws {
        let home = try FixtureTree(name: "empty-home")
        defer { try? FileManager.default.removeItem(at: home.root) }

        let context = ScanContext(homeDirectory: home.root)
        for scanner in ScannerRegistry.defaultScanners()
        where scanner.name != "system-logs" {
            // system-logs scans fixed system paths (/Library/Logs/...) by design and is
            // covered by RulesEngineTests instead of home-fixture tests.
            let result = await scanner.scan(context)
            XCTAssertTrue(result.items.isEmpty, "\(scanner.name) returned items in an empty home")
        }
    }

    func testScannersDoNotFollowSymlinkedDirectories() async throws {
        let home = try FixtureTree.makeHomeLayout()
        defer { try? FileManager.default.removeItem(at: home.root) }

        // Symlink inside Caches pointing at the home root itself (classic loop/escape).
        _ = try home.createSymbolicLink(
            "Library/Caches/escape-link",
            to: home.root
        )

        let result = await UserCachesScanner().scan(ScanContext(homeDirectory: home.root))
        let link = result.items.first { $0.path.lastPathComponent == "escape-link" }
        XCTAssertNotNil(link, "symlink entry itself may be listed…")
        // …but it must contribute zero bytes (never traversed).
        XCTAssertEqual(link?.size, 0)
    }

    func testLargeFilesScannerIsInformationalAndBounded() async throws {
        let home = try FixtureTree.makeHomeLayout()
        defer { try? FileManager.default.removeItem(at: home.root) }

        var config = ScanConfiguration()
        config.largeFileMinimumSize = 32 * 1024 // fixture files are small

        let result = await LargeFilesScanner().scan(ScanContext(homeDirectory: home.root, configuration: config))
        let names = result.items.map { $0.path.lastPathComponent }
        XCTAssertTrue(names.contains("big-file.zip"), "expected big-file.zip, got \(names)")
        XCTAssertFalse(names.contains("app.log"), "Library must be skipped by default")
        XCTAssertTrue(result.items.allSatisfy { $0.category == .largeFiles })
        XCTAssertFalse(JunkCategory.largeFiles.isDeletable)
    }

    func testDuplicatesScannerFindsIdenticalFilesLocally() async throws {
        let home = try FixtureTree(name: "dupes")
        defer { try? FileManager.default.removeItem(at: home.root) }

        let content = Data("identical content for duplicate test".utf8)
        try home.createDirectory("Downloads")
        try content.write(to: home.url("Downloads/copy-a.bin"))
        try content.write(to: home.url("Downloads/copy-b.bin"))
        try Data("unique".utf8).write(to: home.url("Downloads/unique.bin"))

        var config = ScanConfiguration()
        config.duplicateMinimumSize = 8

        let scanner = DuplicatesScanner()
        let result = await scanner.scan(ScanContext(homeDirectory: home.root, configuration: config))

        let names = Set(result.items.map { $0.path.lastPathComponent })
        XCTAssertEqual(names, ["copy-a.bin", "copy-b.bin"])
        XCTAssertTrue(result.items.allSatisfy { $0.detail?.contains("2 identical copies") == true })
        XCTAssertFalse(JunkCategory.duplicates.isDeletable)
    }

    func testLeftoverScannerParsesBundleIDsAndSkipsInstalledAndApple() async throws {
        // Installed app fixture.
        let apps = try FixtureTree(name: "fake-apps")
        defer { try? FileManager.default.removeItem(at: apps.root) }
        try apps.createFile(
            "StillInstalled.app/Contents/Info.plist",
            bytes: 0
        )
        // Real plist with a bundle id:
        let plistURL = apps.url("StillInstalled.app/Contents/Info.plist")
        try ["CFBundleIdentifier": "com.example.stillinstalled"].writePlist(to: plistURL)

        let home = try FixtureTree(name: "leftovers")
        defer { try? FileManager.default.removeItem(at: home.root) }
        let old = Date(timeIntervalSinceNow: -90 * 24 * 60 * 60)
        try home.createFile("Library/Preferences/com.example.stillinstalled.plist", modificationDate: old)
        try home.createFile("Library/Preferences/com.example.goneapp.plist", modificationDate: old)
        try home.createFile("Library/Preferences/com.apple.system.plist", modificationDate: old)
        try home.createFile("Library/Preferences/com.example.fresh.plist") // recent → skipped

        let scanner = LeftoverAppFilesScanner(
            appSearchRoots: [apps.root.path]
        )
        let result = await scanner.scan(ScanContext(homeDirectory: home.root))

        let names = Set(result.items.map { $0.path.lastPathComponent })
        XCTAssertEqual(names, ["com.example.goneapp.plist"],
                       "only exact, non-Apple, non-installed, old bundle ids may be reported")
    }

    func testBundleIDParsingIsConservative() {
        XCTAssertNil(LeftoverAppFilesScanner.bundleID(fromEntryName: "Random Folder", suffix: nil))
        XCTAssertNil(LeftoverAppFilesScanner.bundleID(fromEntryName: "no-dots", suffix: nil))
        // Parsing yields the id; the com.apple.* exclusion is applied by the scanner itself.
        XCTAssertEqual(
            LeftoverAppFilesScanner.bundleID(fromEntryName: "com.apple.Safari", suffix: nil),
            "com.apple.Safari"
        )
        XCTAssertEqual(
            LeftoverAppFilesScanner.bundleID(fromEntryName: "com.example.app.plist", suffix: ".plist"),
            "com.example.app"
        )
        XCTAssertEqual(
            LeftoverAppFilesScanner.bundleID(fromEntryName: "com.example.app.savedState", suffix: ".savedState"),
            "com.example.app"
        )
    }
}

private extension Dictionary where Key == String, Value == String {
    func writePlist(to url: URL) throws {
        _ = try (self as NSDictionary).write(to: url)
    }
}
