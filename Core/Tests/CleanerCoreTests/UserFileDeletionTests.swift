import XCTest
@testable import CleanerCore

/// Large files and duplicates are the user's own files: deletable only when picked, through
/// the Storage checks, and a duplicate group always keeps one verified copy.
final class UserFileDeletionTests: XCTestCase {

    private func write(_ data: Data, to relative: String, in home: FixtureTree) throws -> URL {
        let url = try home.createFile(relative, bytes: 1)
        try data.write(to: url)
        return url
    }

    private func duplicateItem(_ url: URL, groupID: String, home: FixtureTree) -> JunkItem {
        JunkItem(path: url, size: 4, category: .duplicates, riskLevel: .medium,
                 root: home.root, groupID: groupID)
    }

    private func makeDeleter(_ home: FixtureTree) throws -> (SafeDeleter, UndoLog) {
        let rules = RulesEngine(homeDirectory: home.root)
        let log = try UndoLog(directory: makeTempDirectory())
        let userFiles = StorageAnalyzer(rules: rules, applicationRoots: [], systemDataRoots: [])
        return (SafeDeleter(rules: rules, undoLog: log, userFiles: userFiles), log)
    }

    /// Put trashed fixture files back so the real Trash isn't left with them.
    private func restore(_ outcome: SafeDeleter.Outcome, from log: UndoLog) async {
        let entries = await log.all().filter { $0.cleanID == outcome.cleanID }
        _ = UndoRestorer().restore(entries)
    }

    func testPickedLargeFileIsTrashed() async throws {
        let home = try FixtureTree(name: "large")
        let big = try home.createFile("Documents/video.mov", bytes: 4096)
        let item = JunkItem(path: big, size: 4096, category: .largeFiles, riskLevel: .medium, root: home.root)

        let (deleter, log) = try makeDeleter(home)
        let outcome = await deleter.trash([item])

        XCTAssertEqual(outcome.trashed.count, 1, "\(outcome.failures.map(\.reason))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: big.path))
        await restore(outcome, from: log)
        XCTAssertTrue(FileManager.default.fileExists(atPath: big.path))
    }

    func testSelectingEveryCopyStillKeepsOne() async throws {
        let home = try FixtureTree(name: "dupes")
        let content = Data("same".utf8)
        let copies = try ["Downloads/a.txt", "Documents/b.txt", "Desktop/c.txt"].map {
            try write(content, to: $0, in: home)
        }
        let items = copies.map { duplicateItem($0, groupID: "g1", home: home) }

        let (deleter, log) = try makeDeleter(home)
        let outcome = await deleter.trash(items, duplicateGroups: ["g1": copies])

        XCTAssertEqual(outcome.trashed.count, 2)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].reason.contains("last copy"))
        XCTAssertEqual(copies.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 1)
        await restore(outcome, from: log)
    }

    func testDuplicateIsKeptWhenTheOtherCopyChanged() async throws {
        let home = try FixtureTree(name: "changed")
        let first = try write(Data("same".utf8), to: "Downloads/a.txt", in: home)
        let second = try write(Data("same".utf8), to: "Downloads/b.txt", in: home)
        // Edited after the scan: no longer an identical copy.
        try Data("edited".utf8).write(to: second)

        let (deleter, _) = try makeDeleter(home)
        let outcome = await deleter.trash(
            [duplicateItem(first, groupID: "g1", home: home)],
            duplicateGroups: ["g1": [first, second]]
        )

        XCTAssertTrue(outcome.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testUserFilesAreRefusedWithoutUserFileChecks() async throws {
        let home = try FixtureTree(name: "no-policy")
        let big = try home.createFile("Downloads/big.zip", bytes: 10)
        let item = JunkItem(path: big, size: 10, category: .largeFiles, riskLevel: .medium, root: home.root)

        let log = try UndoLog(directory: makeTempDirectory())
        let outcome = await SafeDeleter(rules: RulesEngine(homeDirectory: home.root), undoLog: log).trash([item])

        XCTAssertTrue(outcome.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: big.path))
    }
}
