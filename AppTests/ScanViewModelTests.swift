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
    func testInformationalCategoriesAreNeverSelectableViaToggle() {
        let model = ScanViewModel()
        let bigFile = JunkItem(
            path: URL(fileURLWithPath: "/Users/test/Downloads/big.zip"),
            size: 1_000_000,
            category: .largeFiles,
            riskLevel: .medium,
            root: URL(fileURLWithPath: "/Users/test")
        )
        model.toggle(bigFile)
        XCTAssertTrue(model.selection.isEmpty, "informational items must never enter the selection")
        XCTAssertEqual(model.selectedCount, 0)
    }
}
