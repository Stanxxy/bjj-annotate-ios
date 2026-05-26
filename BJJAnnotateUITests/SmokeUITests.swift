import XCTest

/// Phase 0 XCUITest smoke (PM Marker B: XCUITest only). Boots the app with a clean
/// UserDefaults suite (`--uitest-reset`) and asserts the empty-state copy is visible
/// and the Open Folder button is hittable.
final class SmokeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_cold_launch_shows_empty_state_with_locked_copy_and_open_folder_button() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-reset"]
        app.launch()

        // Locked PM copy must appear verbatim. We assert on substring containment because
        // SwiftUI may insert soft-break characters between display chunks; the load-bearing
        // unique phrase "iCloud Drive folder of BJJ frames" is what we anchor on.
        let copyAnchor = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "iCloud Drive folder of BJJ frames"))
        XCTAssertTrue(copyAnchor.firstMatch.waitForExistence(timeout: 5), "Empty-state PM copy not visible.")

        // Bottom CTA + nav title. Query by accessibility label (works against either the
        // .accessibilityLabel modifier or the inferred label from Text content on the button).
        let openButtonByLabel = app.buttons["Open Folder"]
        XCTAssertTrue(openButtonByLabel.firstMatch.waitForExistence(timeout: 3),
                      "Open Folder button (by label) not found. Tree:\n\(app.debugDescription)")
        XCTAssertTrue(openButtonByLabel.firstMatch.isHittable,
                      "Open Folder button is not hittable on empty state.")

        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 3), "Projects nav title missing.")
    }
}
