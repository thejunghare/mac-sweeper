import XCTest
@testable import CleanerCore

/// Tests for the safety net itself (§9: "test the safety net itself").
final class RulesEngineTests: XCTestCase {

    private var home: FixtureTree!
    private var engine: RulesEngine!

    override func setUpWithError() throws {
        home = try FixtureTree(name: "rules-home")
        engine = RulesEngine(homeDirectory: home.root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.root)
    }

    private func item(
        path: String,
        category: JunkCategory,
        root: String? = nil
    ) -> JunkItem {
        let rootURL = root.map { home.url($0) } ?? home.url(".")
        return JunkItem(
            path: home.url(path),
            size: 1,
            category: category,
            riskLevel: category.riskLevel,
            root: rootURL
        )
    }

    // MARK: Denylist — never deletable even with a scanner bug (defense in depth)

    func testHardDenylistedSystemPathsAreAlwaysDenied() {
        let denials: [(String, JunkCategory)] = [
            ("/System/Library/CoreServices", .systemLogs),
            ("/bin/ls", .systemLogs),
            ("/sbin/launchctl", .systemLogs),
            ("/usr/bin/env", .systemLogs),
            ("/usr/local/bin/tool", .systemLogs),
            ("/Library/Extensions/Foo.kext", .systemLogs),
            ("/private/var/db/anything", .systemLogs),
            ("/Applications/Evil.app/Contents", .systemLogs),
        ]
        for (path, category) in denials {
            let v = engine.validate(
                JunkItem(path: URL(fileURLWithPath: path), size: 1, category: category,
                         riskLevel: .low, root: URL(fileURLWithPath: "/Library/Logs"))
            )
            if case .allow = v {
                XCTFail("denylisted path allowed: \(path)")
            }
            XCTAssertFalse(engine.mayDelete(
                JunkItem(path: URL(fileURLWithPath: path), size: 1, category: category,
                         riskLevel: .low, root: URL(fileURLWithPath: "/Library/Logs"))
            ))
        }
    }

    func testProtectedHomeRootsNeverDeletable() {
        for protected in ["Desktop", "Documents", "Pictures", "Movies"] {
            let v = engine.validate(item(path: "\(protected)/important.docx", category: .userCaches,
                                         root: "Library/Caches"))
            if case .allow = v { XCTFail("\(protected) allowed as deletable") }
        }
    }

    func testDeletableCategoryOutsideAllowedRootIsDenied() {
        // Scanner bug: returns a Documents file as "user cache".
        let v = engine.validate(item(path: "Documents/notes.txt", category: .userCaches,
                                     root: "Library/Caches"))
        if case .allow = v { XCTFail("out-of-root item allowed") }
    }

    func testItemsMustBeStrictlyInsideRoot() {
        // The root itself must never be a deletion candidate.
        let v = engine.validate(item(path: "Library/Caches", category: .userCaches,
                                     root: "Library/Caches"))
        if case .allow = v { XCTFail("root itself allowed as a candidate") }
    }

    func testPathTraversalComponentsAreDenied() {
        var i = item(path: "Library/Caches/ok", category: .userCaches, root: "Library/Caches")
        // Simulate a raw traversal path bypassing standardization:
        i = JunkItem(path: URL(fileURLWithPath: home.root.path + "/Library/Caches/../Desktop/x"),
                     size: 1, category: .userCaches, riskLevel: .low, root: home.url("Library/Caches"))
        // standardizedFileURL in the initializer collapses "..", landing outside the root:
        if case .allow = engine.validate(i) {
            // If standardization already collapsed it outside root, this must fail:
            XCTFail("traversal that escapes root must be denied")
        }
    }

    func testValidCacheItemIsAllowed() {
        let v = engine.validate(item(path: "Library/Caches/com.example/cache.bin",
                                     category: .userCaches, root: "Library/Caches"))
        if case .allow(let risk) = v {
            XCTAssertEqual(risk, .low)
        } else {
            XCTFail("valid cache item denied")
        }
        XCTAssertTrue(engine.mayDelete(item(path: "Library/Caches/com.example/cache.bin",
                                            category: .userCaches, root: "Library/Caches")))
    }

    func testInformationalCategoriesAreNeverDeletable() {
        XCTAssertFalse(engine.mayDelete(item(path: "Downloads/big.zip", category: .largeFiles,
                                             root: "")))
        XCTAssertFalse(engine.mayDelete(item(path: "Downloads/a.bin", category: .duplicates,
                                             root: "")))
    }

    func testHighRiskCategoryKeepsItsTier() {
        let v = engine.validate(item(path: "Library/Application Support/MobileSync/Backup/ABC",
                                     category: .iosDeviceBackups,
                                     root: "Library/Application Support/MobileSync/Backup"))
        if case .allow(let risk) = v {
            XCTAssertEqual(risk, .high)
        } else {
            XCTFail("valid backup item denied")
        }
    }

    func testHardDenylistIsPrefixSafe() {
        // /usr must not deny /usrinary? No — but /usrfoo must not be denied by /usr either.
        let v = engine.validate(JunkItem(path: URL(fileURLWithPath: "/usrfoo/bar"),
                                         size: 1, category: .systemLogs, riskLevel: .low,
                                         root: URL(fileURLWithPath: "/Library/Logs")))
        // /usrfoo is outside home and outside allowed roots → denied anyway, but NOT by
        // the /usr denylist entry (no false prefix match).
        if case .deny(let reason) = v {
            XCTAssertFalse(reason.contains("hard denylist: /usr\n") || reason == "hard denylist: /usr",
                           "prefix matching must require a path boundary")
        }
    }
}
