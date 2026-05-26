import XCTest

/// Finding #3 — Designer Resolution #3 mandates: toolbar `+` ONLY on populated state;
/// the bottom `Open Folder` CTA appears ONLY on the empty state. This test seeds a single
/// project (`--uitest-seed-empty-folder` is sufficient — it creates a populated list with
/// one entry) and asserts the bottom CTA accessibility identifier is NOT present on the
/// populated list, while the toolbar `+` (labelled "Open Folder") IS hittable.
final class PopulatedListNoBottomCTAUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_populated_list_hides_bottom_open_folder_cta_and_keeps_toolbar_plus() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-seed-empty-folder"]
        app.launch()

        // Wait for the list to render.
        let firstRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ProjectList.Row.'")
        ).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "List row never appeared.")

        // The bottom CTA carries identifier ProjectList.OpenFolderButton. It must be
        // ABSENT from the populated state.
        let bottomCTA = app.buttons["ProjectList.OpenFolderButton"]
        XCTAssertFalse(
            bottomCTA.exists,
            "Bottom Open Folder CTA must NOT appear on the populated state (Designer Resolution #3)."
        )

        // The toolbar `+` button uses accessibilityLabel "Open Folder". It must be present
        // and hittable. There is exactly one such button on populated state (toolbar only).
        let toolbarPlus = app.navigationBars["Projects"].buttons["Open Folder"]
        XCTAssertTrue(toolbarPlus.waitForExistence(timeout: 3),
                      "Toolbar + (Open Folder) button missing on populated list.")
        XCTAssertTrue(toolbarPlus.isHittable, "Toolbar + must be hittable.")
    }
}
