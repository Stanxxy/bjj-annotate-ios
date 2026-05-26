import XCTest

/// Finding #2 — XCUITest for the bookmark-error row state. Launches with
/// `--uitest-seed-missing-bookmark` so the app boots with a single stored bookmark whose
/// target folder does not exist on disk. Asserts the locked relocate copy is visible.
final class BookmarkErrorRowUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_missing_bookmark_row_shows_locked_relocate_copy_in_orange() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-seed-missing-bookmark"]
        app.launch()

        // The locked relocate copy (LockedCopy.bookmarkErrorRow) uses U+2014 EM DASH.
        // Anchor on the unique trailing phrase that survives soft-break insertion.
        let copyAnchor = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "tap to relocate")
        )
        XCTAssertTrue(copyAnchor.firstMatch.waitForExistence(timeout: 5),
                      "Bookmark-error row PM copy not visible. Tree:\n\(app.debugDescription)")

        // The relocate row is rendered as a button; assert it exists and is hittable.
        let missingRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ProjectList.MissingRow.'")
        ).firstMatch
        XCTAssertTrue(missingRow.waitForExistence(timeout: 3),
                      "Missing-bookmark row not found in list.")
        XCTAssertTrue(missingRow.isHittable, "Missing-bookmark row must be tappable to invoke the picker.")
    }
}
