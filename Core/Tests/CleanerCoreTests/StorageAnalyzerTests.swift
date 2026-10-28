import XCTest
@testable import CleanerCore

final class StorageAnalyzerTests: XCTestCase {

    /// Analyzer pointed only at fixture folders — never the real /Applications or /Library.
    private func analyzer(for home: FixtureTree, minimumListedSize: Int64 = 1_000) -> StorageAnalyzer {
        StorageAnalyzer(
            rules: RulesEngine(homeDirectory: home.root),
            applicationRoots: [home.url("Applications")],
            systemDataRoots: [home.url("Library/Caches"), home.url("Library/Application Support"),
                              home.url("Library/Containers")],
            minimumListedSize: minimumListedSize
        )
    }

    // MARK: Flags

    func testFlags() throws {
        let home = try FixtureTree.makeHomeLayout()
        let sut = analyzer(for: home)

        let cache = try home.createFile("Library/Caches/com.example.app/blob.bin")
        XCTAssertEqual(sut.flag(for: cache).flag, .safe)

        let document = try home.createFile("Documents/report.pdf")
        XCTAssertEqual(sut.flag(for: document).flag, .checkFirst)

        let support = try home.createDirectory("Library/Application Support/com.example.app")
        XCTAssertEqual(sut.flag(for: support).flag, .checkFirst)

        let trashed = home.url(".Trash/old-document.pdf")
        XCTAssertEqual(sut.flag(for: trashed).flag, .cannotDelete)

        let photos = try home.createDirectory("Pictures/Photos Library.photoslibrary")
        XCTAssertEqual(sut.flag(for: photos).flag, .cannotDelete)

        let container = try home.createDirectory("Library/Containers/com.example.sandboxed")
        XCTAssertEqual(sut.flag(for: container).flag, .cannotDelete)

        let mailDownload = try home.createFile(
            "Library/Containers/com.apple.mail/Data/Library/Mail Downloads/invoice.pdf"
        )
        XCTAssertEqual(sut.flag(for: mailDownload).flag, .checkFirst)
    }

    func testFoldersThatHoldEverythingCannotBeDeleted() throws {
        let home = try FixtureTree.makeHomeLayout()
        try home.createDirectory("Documents")
        let sut = analyzer(for: home)

        for folder in ["", "Library", "Library/Caches", "Documents", "Downloads", "Applications"] {
            XCTAssertEqual(sut.flag(for: home.url(folder)).flag, .cannotDelete, folder)
        }
        XCTAssertEqual(sut.flag(for: URL(fileURLWithPath: "/System/Library/Kernels/kernel")).flag, .cannotDelete)
        XCTAssertEqual(sut.flag(for: URL(fileURLWithPath: "/usr/bin/ls")).flag, .cannotDelete)
    }

    // MARK: Sections

    func testApplicationsSectionListsAppsBySize() throws {
        let home = try FixtureTree.makeHomeLayout()
        try home.createFile("Applications/Big.app/Contents/MacOS/big", bytes: 64 * 1024)
        try home.createFile("Applications/Small.app/Contents/MacOS/small", bytes: 1024)

        let report = analyzer(for: home).analyze(.applications)
        XCTAssertEqual(report.entries.map(\.path.lastPathComponent), ["Big.app", "Small.app"])
        XCTAssertTrue(report.entries.allSatisfy { $0.flag == .checkFirst })
        XCTAssertGreaterThan(report.totalSize, 0)
    }

    func testDocumentsSectionListsLargeUserFilesOutsideLibrary() throws {
        let home = try FixtureTree.makeHomeLayout()
        try home.createFile("Documents/big.bin", bytes: 64 * 1024)
        try home.createFile("Downloads/tiny.txt", bytes: 10)
        try home.createFile("Library/Caches/com.example.app/huge.bin", bytes: 128 * 1024)

        let report = analyzer(for: home, minimumListedSize: 32 * 1024).analyze(.documents)
        let names = report.entries.map(\.path.lastPathComponent)
        XCTAssertTrue(names.contains("big.bin"))
        XCTAssertTrue(names.contains("big-file.zip"))
        XCTAssertFalse(names.contains("tiny.txt"))
        XCTAssertFalse(names.contains("huge.bin"), "Library content belongs to System Data")
    }

    func testTrashSectionIsNeverDeletable() throws {
        let home = try FixtureTree.makeHomeLayout()
        let report = analyzer(for: home).analyze(.trash)
        XCTAssertEqual(report.entries.map(\.path.lastPathComponent), ["old-document.pdf"])
        XCTAssertTrue(report.entries.allSatisfy { $0.flag == .cannotDelete })
    }

    func testSystemDataFlagsCachesSafe() throws {
        let home = try FixtureTree.makeHomeLayout()
        let report = analyzer(for: home).analyze(.systemData)
        let junk = try XCTUnwrap(report.entries.first { $0.path.lastPathComponent == "com.example.junkcache" })
        XCTAssertEqual(junk.flag, .safe)
        XCTAssertFalse(report.safeEntries.isEmpty)
    }

    // MARK: Deletion

    func testDeleterTrashesUserFileAndUndoRestoresIt() async throws {
        let home = try FixtureTree.makeHomeLayout()
        let file = try home.createFile("Documents/old-video.mov", bytes: 64 * 1024)
        let original = try Data(contentsOf: file)
        let sut = analyzer(for: home, minimumListedSize: 32 * 1024)
        let entries = sut.analyze(.documents).entries
        let entry = try XCTUnwrap(entries.first { $0.path.lastPathComponent == "old-video.mov" })

        let undoLog = try UndoLog(directory: makeTempDirectory())
        let outcome = await StorageDeleter(analyzer: sut, undoLog: undoLog).trash([entry])

        XCTAssertEqual(outcome.trashed.count, 1, "\(outcome.failures.map(\.reason))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let undoEntries = await undoLog.all().filter { $0.cleanID == outcome.cleanID }
        let restored = UndoRestorer().restore(undoEntries)
        XCTAssertEqual(restored.restored.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testDeleterRefusesItemsThatCannotBeDeleted() async throws {
        let home = try FixtureTree.makeHomeLayout()
        let sut = analyzer(for: home)
        let trashEntry = try XCTUnwrap(sut.analyze(.trash).entries.first)
        // Even if the UI were tricked into passing a "Can delete" flag for a kept folder,
        // the deleter recomputes the flag from disk.
        let forged = StorageEntry(
            path: home.url("Library/Caches"),
            size: 1,
            isDirectory: true,
            modificationDate: nil,
            flag: .safe,
            note: "",
            root: home.url("Library"),
            section: .systemData
        )

        let undoLog = try UndoLog(directory: makeTempDirectory())
        let outcome = await StorageDeleter(analyzer: sut, undoLog: undoLog).trash([trashEntry, forged])

        XCTAssertTrue(outcome.trashed.isEmpty)
        XCTAssertEqual(outcome.failures.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.url("Library/Caches").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashEntry.path.path))
    }
}
