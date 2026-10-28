import XCTest
@testable import CleanerCore

final class DeepestFileFinderTests: XCTestCase {

    private func finder(for home: FixtureTree) -> DeepestFileFinder {
        DeepestFileFinder(rules: RulesEngine(homeDirectory: home.root))
    }

    func testFindsTheMostDeeplyNestedFile() throws {
        let home = try FixtureTree.makeHomeLayout()
        try home.createFile("Downloads/a/b/c/d/deep.txt", bytes: 300)

        let result = try XCTUnwrap(finder(for: home).find())
        XCTAssertEqual(result.path.lastPathComponent, "deep.txt")
        XCTAssertEqual(result.depth, 6) // Downloads/a/b/c/d/deep.txt
        XCTAssertEqual(result.otherFilesAtSameDepth, 0)
        XCTAssertGreaterThan(result.filesExamined, 1)
        XCTAssertGreaterThan(result.size, 0)
    }

    func testFileInCacheLocationIsDeletable() throws {
        let home = try FixtureTree.makeHomeLayout()
        try home.createFile("Library/Caches/com.example.app/x/y/z/w/blob.bin")

        let result = try XCTUnwrap(finder(for: home).find())
        XCTAssertEqual(result.path.lastPathComponent, "blob.bin")
        XCTAssertTrue(result.verdict.canDelete, result.verdict.reason)
        XCTAssertEqual(result.verdict.category, .userCaches)
        XCTAssertEqual(result.verdict.riskLevel, .low)
    }

    func testMostSpecificCategoryWins() throws {
        let home = try FixtureTree.makeHomeLayout()
        try home.createFile("Library/Caches/Homebrew/downloads/a/b/c/pkg.tar")

        let result = try XCTUnwrap(finder(for: home).find())
        XCTAssertEqual(result.verdict.category, .homebrewCache)
        XCTAssertTrue(result.verdict.canDelete)
    }

    func testFileInDocumentsIsNotDeletable() throws {
        let home = try FixtureTree.makeHomeLayout()
        try home.createFile("Documents/thesis/chapters/1/drafts/v2/final.docx")

        let result = try XCTUnwrap(finder(for: home).find())
        XCTAssertEqual(result.path.lastPathComponent, "final.docx")
        XCTAssertFalse(result.verdict.canDelete)
        XCTAssertNil(result.verdict.category)
        XCTAssertTrue(result.verdict.reason.contains("Documents"))
    }

    func testFileOutsideJunkLocationsIsNotDeletable() throws {
        let home = try FixtureTree.makeHomeLayout()
        try home.createFile("Projects/app/src/main/java/App.java")

        let result = try XCTUnwrap(finder(for: home).find())
        XCTAssertFalse(result.verdict.canDelete)
        XCTAssertTrue(result.verdict.reason.contains("Not in a junk location"))
    }

    func testTrashAndLeftoverLocationsAreNotDeletableByLocationAlone() throws {
        let home = try FixtureTree.makeHomeLayout()
        let sut = finder(for: home)

        let trashed = try home.createFile(".Trash/old/a/b/file.txt")
        XCTAssertFalse(sut.verdict(for: trashed).canDelete)

        // Application Support files belong to installed apps unless the leftover scanner
        // proves the owner is gone — location alone must never make them deletable.
        let support = try home.createFile("Library/Application Support/com.example.app/db.sqlite")
        XCTAssertFalse(sut.verdict(for: support).canDelete)
    }

    func testDenylistedPathIsNotDeletable() {
        let sut = DeepestFileFinder(rules: RulesEngine(homeDirectory: URL(fileURLWithPath: "/Users/test")))
        let verdict = sut.verdict(for: URL(fileURLWithPath: "/System/Library/Kernels/kernel"))
        XCTAssertFalse(verdict.canDelete)
        XCTAssertTrue(verdict.reason.contains("denylist"))
    }

    func testDoesNotFollowSymlinkedDirectories() throws {
        let home = try FixtureTree.makeHomeLayout()
        let outside = try FixtureTree(name: "outside")
        try outside.createFile("a/b/c/d/e/f/g/h/escape.txt")
        try home.createSymbolicLink("Downloads/link", to: outside.root)

        let result = try withExtendedLifetime(outside) {
            try XCTUnwrap(finder(for: home).find())
        }
        XCTAssertNotEqual(result.path.lastPathComponent, "escape.txt")
        XCTAssertFalse(result.path.path.contains("/link/"))
    }

    func testTiesAreBrokenAlphabeticallyAndCounted() throws {
        let home = try FixtureTree(name: "ties")
        try home.createFile("x/y/b.txt")
        try home.createFile("x/y/a.txt")
        try home.createFile("x/top.txt")

        let result = try XCTUnwrap(finder(for: home).find())
        XCTAssertEqual(result.path.lastPathComponent, "a.txt")
        XCTAssertEqual(result.depth, 3)
        XCTAssertEqual(result.otherFilesAtSameDepth, 1)
    }

    func testEmptyTreeReturnsNil() throws {
        let home = try FixtureTree(name: "empty")
        try home.createDirectory("a/b/c")
        XCTAssertNil(finder(for: home).find())
    }

    func testFinderIsReadOnly() throws {
        let home = try FixtureTree.makeHomeLayout()
        let file = try home.createFile("Library/Caches/com.example.app/x/y/blob.bin")
        let before = try Data(contentsOf: file)

        _ = finder(for: home).find()

        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    // MARK: Suggestions

    func testSuggestsOnlyFilesInJunkLocations() throws {
        let home = try FixtureTree.makeHomeLayout()
        try home.createFile("Documents/notes/todo.txt")

        let result = try XCTUnwrap(finder(for: home).find())
        let names = Set(result.suggestions.map { $0.item.path.lastPathComponent })
        XCTAssertEqual(names, ["blob.bin", "pkg.tar", "page.bin", "app.log"])
        XCTAssertTrue(result.suggestions.allSatisfy { $0.item.category.isDeletable })
        XCTAssertEqual(
            result.suggestions.first { $0.item.path.lastPathComponent == "pkg.tar" }?.item.category,
            .homebrewCache
        )
    }

    func testSuggestionsAreDeepestFirstAndBounded() throws {
        let home = try FixtureTree(name: "bounded")
        for index in 0..<10 {
            try home.createFile("Library/Caches/app\(index)/" + String(repeating: "d/", count: index) + "f.bin")
        }

        let sut = DeepestFileFinder(rules: RulesEngine(homeDirectory: home.root), suggestionLimit: 3)
        let result = try XCTUnwrap(sut.find())
        XCTAssertEqual(result.suggestions.count, 3)
        XCTAssertEqual(result.suggestions.map(\.depth), [13, 12, 11])
    }

    func testHighRiskBackupsAreNeverSuggested() throws {
        let home = try FixtureTree(name: "backups")
        try home.createFile("Library/Application Support/MobileSync/Backup/device/aa/blob")

        let result = try XCTUnwrap(finder(for: home).find())
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    func testSuggestionsCanBeTrashedBySafeDeleter() async throws {
        let home = try FixtureTree.makeHomeLayout()
        let rules = RulesEngine(homeDirectory: home.root)
        let result = try XCTUnwrap(DeepestFileFinder(rules: rules).find())
        let items = result.suggestions.map(\.item)
        XCTAssertFalse(items.isEmpty)

        let undoLog = try UndoLog(directory: makeTempDirectory())
        let outcome = await SafeDeleter(rules: rules, undoLog: undoLog).trash(items)

        XCTAssertEqual(outcome.trashed.count, items.count, "\(outcome.failures.map(\.reason))")
        for item in items {
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path.path))
        }
        // Put them back so the real Trash isn't left with fixture files.
        let entries = await undoLog.all()
        _ = UndoRestorer().restore(entries)
    }
}
