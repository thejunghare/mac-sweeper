import XCTest
@testable import CleanerCore

/// Symlink / TOCTOU escape tests (§9).
final class SymlinkGuardTests: XCTestCase {

    func testRejectsItemWhoseParentSymlinkEscapesRoot() throws {
        let tree = try FixtureTree(name: "symlink-escape")
        defer { try? FileManager.default.removeItem(at: tree.root) }

        let root = try tree.createDirectory("swept")
        let outside = try tree.createDirectory("outside")
        try tree.createFile("outside/victim.txt", bytes: 100)

        // Swap: "swept/redirect" → outside/
        let redirect = try tree.createSymbolicLink("swept/redirect", to: outside)
        _ = try tree.createFile("outside/inner.txt", bytes: 10)

        // An item *inside the symlinked dir* must be rejected: its parent chain resolves
        // outside the declared root.
        let escaping = JunkItem(
            path: redirect.appendingPathComponent("inner.txt"),
            size: 10,
            category: .userCaches,
            riskLevel: .low,
            root: root
        )
        let symlinkGuard = SymlinkGuard()
        let reason = symlinkGuard.rejectionReason(for: escaping)
        XCTAssertNotNil(reason, "item reached via escaping symlink must be rejected")

        // And the symlink itself inside the root is fine to trash (relocates the link only).
        let linkItem = JunkItem(path: redirect, size: 0, category: .userCaches,
                                riskLevel: .low, root: root)
        XCTAssertNil(symlinkGuard.rejectionReason(for: linkItem),
                     "trashing a link inside the root does not follow the link")
    }

    func testAcceptsRegularItemInsideRoot() throws {
        let tree = try FixtureTree(name: "symlink-ok")
        defer { try? FileManager.default.removeItem(at: tree.root) }

        let root = try tree.createDirectory("swept")
        let file = try tree.createFile("swept/file.bin", bytes: 10)

        let item = JunkItem(path: file, size: 10, category: .userCaches,
                            riskLevel: .low, root: root)
        XCTAssertNil(SymlinkGuard().rejectionReason(for: item))
    }

    func testRejectsTraversalInRawPath() throws {
        let tree = try FixtureTree(name: "symlink-traversal")
        defer { try? FileManager.default.removeItem(at: tree.root) }

        let root = try tree.createDirectory("swept")
        let item = JunkItem(path: URL(fileURLWithPath: root.path + "/../Desktop/secret"),
                            size: 1, category: .userCaches, riskLevel: .low, root: root)
        // The initializer standardizes the URL, so ".." is gone but the location is outside
        // the root — must be rejected either way.
        if let reason = SymlinkGuard().rejectionReason(for: item) {
            XCTAssertNotNil(reason)
        } else {
            XCTFail("escaped path accepted")
        }
    }

    func testRejectsMissingRoot() throws {
        let tree = try FixtureTree(name: "symlink-noroot")
        defer { try? FileManager.default.removeItem(at: tree.root) }

        let file = try tree.createFile("a/b.txt", bytes: 1)
        let item = JunkItem(path: file, size: 1, category: .userCaches, riskLevel: .low,
                            root: tree.url("does-not-exist"))
        XCTAssertEqual(SymlinkGuard().rejectionReason(for: item), .rootMissing)
    }

    func testRootItselfSymlinkedIsConsistentBothSidesResolved() throws {
        let tree = try FixtureTree(name: "symlink-root")
        defer { try? FileManager.default.removeItem(at: tree.root) }

        let realRoot = try tree.createDirectory("real-caches")
        let file = try tree.createFile("real-caches/file.bin", bytes: 5)
        let linkRoot = try tree.createSymbolicLink("caches-link", to: realRoot)

        // Declared root is the symlink; item lives under the real path — accepted
        // because both sides resolve identically.
        let item = JunkItem(path: file, size: 5, category: .userCaches, riskLevel: .low,
                            root: linkRoot)
        XCTAssertNil(SymlinkGuard().rejectionReason(for: item))
    }
}
