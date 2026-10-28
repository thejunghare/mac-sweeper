import CleanerCore
import XCTest
@testable import Broom

/// App-target smoke tests (the deep safety tests live in Core/Tests).
final class ScanViewModelTests: XCTestCase {

    @MainActor
    func testDefaultsEnableAllCategories() {
        UserDefaults.standard.removeObject(forKey: "broom.enabledCategories")
        let model = ScanViewModel()
        XCTAssertEqual(model.enabledCategories, Set(JunkCategory.allCases))
        XCTAssertEqual(model.largeFileMinimumMB, 500)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.selection.isEmpty)
    }

    @MainActor
    func testCategoryTogglesPersist() {
        let model = ScanViewModel()
        model.enabledCategories.remove(.trash)
        XCTAssertTrue(
            UserDefaults.standard.stringArray(forKey: "broom.enabledCategories")?
                .contains("trash") == false
        )
        model.enabledCategories.insert(.trash)
    }

    @MainActor
    func testUserFilesCanBePickedButLastDuplicateCopyCannot() {
        let model = ScanViewModel()
        let home = URL(fileURLWithPath: "/Users/test")
        let bigFile = JunkItem(
            path: home.appendingPathComponent("Downloads/big.zip"),
            size: 1_000_000,
            category: .largeFiles,
            riskLevel: .medium,
            root: home
        )
        model.toggle(bigFile)
        XCTAssertTrue(model.selection.contains(bigFile.id), "large files can be picked by the user")

        // A duplicate with no other known copy is the last copy — never selectable.
        let loneCopy = JunkItem(
            path: home.appendingPathComponent("Downloads/a.bin"),
            size: 10,
            category: .duplicates,
            riskLevel: .medium,
            root: home,
            groupID: "g1"
        )
        model.toggle(loneCopy)
        XCTAssertFalse(model.selection.contains(loneCopy.id))
    }
}
