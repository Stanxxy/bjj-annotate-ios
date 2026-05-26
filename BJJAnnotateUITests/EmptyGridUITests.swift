import XCTest

/// Finding #1 — XCUITest for the empty-folder grid state. Launches with
/// `--uitest-seed-empty-folder` so the app boots directly into the populated project list
/// (with one seeded project pointing at a freshly-created empty folder), then taps that
/// row to reach the grid and asserts the locked empty-folder copy is on screen.
final class EmptyGridUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_navigating_to_seeded_empty_folder_shows_locked_empty_grid_copy() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-seed-empty-folder"]
        app.launch()

        // The seed flag should have inserted exactly one bookmark, so the list is
        // populated, not empty. Tap the first row to push into the grid.
        let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ProjectList.Row.'")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5),
                      "Seeded project row not found. Tree:\n\(app.debugDescription)")
        firstRow.tap()

        // Locked PM copy from LockedCopy.emptyProjectGrid. Anchor on a uniquely-phrased
        // substring so SwiftUI soft-break insertions don't break the assertion.
        let copyAnchor = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "This folder has no images yet")
        )
        XCTAssertTrue(copyAnchor.firstMatch.waitForExistence(timeout: 5),
                      "Empty-folder grid PM copy not visible. Tree:\n\(app.debugDescription)")

        // Pull-to-refresh affordance lives on the empty state ScrollView; assert the empty
        // state container exists by accessibility identifier.
        XCTAssertTrue(app.otherElements["ProjectGrid.EmptyState"].waitForExistence(timeout: 2),
                      "Empty-state container missing identifier ProjectGrid.EmptyState.")
    }
}
