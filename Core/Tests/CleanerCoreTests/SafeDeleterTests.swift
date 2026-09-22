import XCTest
@testable import CleanerCore

/// Delete → undo → byte-identical restore tests, plus deletion-safety gates (§9).
final class SafeDeleterTests: XCTestCase {

    private var home: FixtureTree!
    private var supportDir: URL!

    override func setUpWithError() throws {
        home = try FixtureTree(name: "deleter-home")
        supportDir = try makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.root)
    }

    private func makeDeleter() throws -> (SafeDeleter, UndoLog) {
        let log = try UndoLog(directory: supportDir)
        let deleter = SafeDeleter(
            rules: RulesEngine(homeDirectory: home.root),
            undoLog: log
        )
        return (deleter, log)
    }

    private func cacheItem(_ relative: String, bytes: Int = 100) throws -> JunkItem {
        let file = try home.createFile(relative, bytes: bytes)
        return JunkItem(
            path: file,
            size: Int64(bytes),
            category: .userCaches,
            riskLevel: .low,
            root: home.url("Library/Caches")
        )
    }

    // MARK: Core round-trip

    func testDeleteThenUndoRestoresByteIdenticalFile() async throws {
        let payload = Data((0..<2048).map { _ in UInt8.random(in: 0...255) })
        let file = try home.createFile("Library/Caches/payload.bin")
        try payload.write(to: file)

        let item = JunkItem(path: file, size: Int64(payload.count), category: .userCaches,
                            riskLevel: .low, root: home.url("Library/Caches"))

        let (deleter, log) = try makeDeleter()
        let outcome = await deleter.trash([item])
        XCTAssertEqual(outcome.trashed.count, 1)
        XCTAssertEqual(outcome.failures.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "item must leave its original location")

        let entries = await log.entriesForLastClean()
        XCTAssertEqual(entries.count, 1)

        let restorer = UndoRestorer()
        let result = await restorer.restoreLastClean(from: log)
        XCTAssertEqual(result.restored.count, 1, "restore skipped: \(result.skipped.map(\.reason))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), payload, "restored file must be byte-identical")
    }

    func testDeletionUsesTrashNotUnlink() async throws {
        let item = try cacheItem("Library/Caches/todelete.bin")
        let (deleter, _) = try makeDeleter()
        let outcome = await deleter.trash([item])

        guard let trashURL = outcome.trashed.first?.trashURL else {
            return XCTFail("no trash URL recorded — was the item unlinked instead?")
        }        // FileManager.trashItem relocates to the user's .Trash.
        XCTAssertTrue(trashURL.path.contains(".Trash"),
                      "expected Trash relocation, got \(trashURL.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
    }

    // MARK: Safety gates

    func testDeleterRefusesDenylistedPaths() async throws {
        let sneaky = JunkItem(
            path: URL(fileURLWithPath: "/System/Library/CoreServices/Important"),
            size: 10,
            category: .userCaches,
            riskLevel: .low,
            root: URL(fileURLWithPath: "/System")
        )
        let (deleter, _) = try makeDeleter()
        let outcome = await deleter.trash([sneaky])
        XCTAssertEqual(outcome.trashed.count, 0)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures.first?.reason.contains("rules engine") == true)
    }

    func testDeleterRefusesInformationalCategories() async throws {
        let big = try home.createFile("Downloads/big.zip", bytes: 10)
        let item = JunkItem(path: big, size: 10, category: .largeFiles, riskLevel: .medium,
                            root: home.root)
        let (deleter, _) = try makeDeleter()
        let outcome = await deleter.trash([item])
        XCTAssertEqual(outcome.trashed.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: big.path))
    }

    func testDeleterRefusesItemsEscapingRootViaSymlinkParent() async throws {
        let outside = try home.createDirectory("outside")
        try home.createFile("outside/victim.txt", bytes: 42)
        _ = try home.createSymbolicLink("Library/Caches/escape", to: outside)

        let escaping = JunkItem(
            path: home.url("Library/Caches/escape/victim.txt"),
            size: 42,
            category: .userCaches,
            riskLevel: .low,
            root: home.url("Library/Caches")
        )
        let (deleter, _) = try makeDeleter()
        let outcome = await deleter.trash([escaping])

        XCTAssertEqual(outcome.trashed.count, 0, "symlink escape must be blocked at delete time")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.url("outside/victim.txt").path),
                      "victim file must remain untouched")
    }

    func testTrashCategoryItemsAreNeverAutoPurged() async throws {
        let trashedFile = try home.createFile(".Trash/keepme.pdf", bytes: 10)
        let item = JunkItem(path: trashedFile, size: 10, category: .trash, riskLevel: .low,
                            root: home.url(".Trash"))
        let (deleter, _) = try makeDeleter()
        let outcome = await deleter.trash([item])
        XCTAssertEqual(outcome.trashed.count, 0, "Trash contents must never be auto-purged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedFile.path))
    }

    func testProgressIsReportedPerItem() async throws {
        let items = try (1...5).map { i in try cacheItem("Library/Caches/f\(i).bin") }
        let (deleter, _) = try makeDeleter()

        let recorder = ProgressRecorder<Int>()
        _ = await deleter.trash(items) { progress in
            recorder.record(progress.completed)
        }
        XCTAssertEqual(recorder.values, [1, 2, 3, 4, 5])
    }

    func testUndoRefusesToOverwriteReoccupiedPath() async throws {
        let item = try cacheItem("Library/Caches/file.bin")
        let (deleter, log) = try makeDeleter()
        let outcome = await deleter.trash([item])
        XCTAssertEqual(outcome.trashed.count, 1)

        // Recreate something at the original path.
        try home.createFile("Library/Caches/file.bin", bytes: 3)

        let entries = await log.entriesForLastClean()
        let result = UndoRestorer().restore(entries)
        XCTAssertEqual(result.restored.count, 0)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path.path),
                      "undo must never overwrite live data")
    }
}
