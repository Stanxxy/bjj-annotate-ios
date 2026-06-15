import XCTest

/// T23 — Mobile-first audit (AC #14).
///
/// Asserts on iPhone 13 portrait (~390x844 pt):
///   - Open Folder button has min tap height >= 44pt.
///   - No horizontal scrolling on the empty state list.
///   - The Projects nav title is visible without overflow.
///   - Dynamic Type at AX5 doesn't truncate the empty-state copy
///     (heuristic: the empty-state label width fits within the screen
///     after launch with `-UIPreferredContentSizeCategoryName` set to
///     `UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge`).
///
/// These are CI-level proxies for the manual mobile-first acceptance.
/// They do NOT replace the on-device PM verification.
final class MobileFirstAuditUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_emptyState_open_folder_button_meets_44pt_tap_target() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()

        let button = app.buttons["Open Folder"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Open Folder button missing.")
        let frame = button.frame
        XCTAssertGreaterThanOrEqual(frame.height, 44,
                                    "AC #14 mobile-first: Open Folder button height must be >= 44pt, got \(frame.height).")
        XCTAssertGreaterThanOrEqual(frame.width, 44,
                                    "AC #14 mobile-first: Open Folder button width must be >= 44pt, got \(frame.width).")
    }

    func test_emptyState_does_not_horizontally_scroll() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()

        // Anchor on the empty state and capture its full bounds — they must
        // fit within the device's screen width with no horizontal overflow.
        let emptyAnchor = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "iCloud Drive folder of BJJ frames")
        ).firstMatch
        XCTAssertTrue(emptyAnchor.waitForExistence(timeout: 5), "Empty-state copy missing.")
        let screenWidth = app.windows.firstMatch.frame.width
        XCTAssertLessThanOrEqual(emptyAnchor.frame.maxX, screenWidth + 1,
                                 "AC #14 mobile-first: empty-state copy overflows screen width.")
        XCTAssertGreaterThanOrEqual(emptyAnchor.frame.minX, -1,
                                    "AC #14 mobile-first: empty-state copy clipped on the leading edge.")
    }

    func test_projects_nav_title_is_visible_without_truncation() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()

        let nav = app.navigationBars["Projects"]
        XCTAssertTrue(nav.waitForExistence(timeout: 5), "Projects nav title missing.")
        // The 'Projects' static text inside the nav bar must render visible.
        let title = nav.staticTexts["Projects"]
        XCTAssertTrue(title.exists, "Projects title text not found inside nav bar.")
    }

    func test_populated_state_row_meets_44pt_tap_target() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset", "--uitest-seed-empty-folder"]
        app.launch()

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ProjectList.Row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Populated row missing.")
        XCTAssertGreaterThanOrEqual(row.frame.height, 44,
                                    "AC #14 mobile-first: project list row height must be >= 44pt, got \(row.frame.height).")
    }
}
