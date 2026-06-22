import XCTest
@testable import BJJAnnotate

/// Phase 1 locked-copy invariants. Eleven strings sourced from:
///  - PM acceptance pack §Locked PM-owned strings (9 strings)
///  - PM addendum §10 (10th string — athlete cap)
///  - PM addendum Designer Resolutions §3 (11th string — instance-list empty state)
///
/// Em-dashes are U+2014. Phase 0 `LockedCopyTests` already covers the empty-project-list,
/// bookmark-error-row, and empty-project-grid strings.
final class Phase1LockedCopyTests: XCTestCase {

    func test_keypointsDisabledTooltip_matches_locked_string() {
        XCTAssertEqual(LockedCopy.keypointsDisabledTooltip, "Keypoints \u{2014} Phase 2")
    }

    func test_newAthleteRow_matches_locked_string() {
        XCTAssertEqual(LockedCopy.newAthleteRow, "+ New athlete")
    }

    func test_boxTooSmallToast_matches_locked_string() {
        XCTAssertEqual(LockedCopy.boxTooSmallToast, "Box too small \u{2014} drag a larger area.")
    }

    func test_classChipGi_matches_locked_string() {
        XCTAssertEqual(LockedCopy.classChipGi, "Gi")
    }

    func test_classChipNoGi_matches_locked_string() {
        XCTAssertEqual(LockedCopy.classChipNoGi, "NoGi")
    }

    func test_classChipRef_matches_locked_string() {
        XCTAssertEqual(LockedCopy.classChipRef, "Ref")
    }

    func test_athleteRowFormat_renders_N_without_padding() {
        XCTAssertEqual(LockedCopy.athleteRow(id: 1), "athlete-1")
        XCTAssertEqual(LockedCopy.athleteRow(id: 8), "athlete-8")
        XCTAssertEqual(LockedCopy.athleteRow(id: 12), "athlete-12")
    }

    func test_conflictBanner_matches_locked_string() {
        XCTAssertEqual(
            LockedCopy.conflictBanner,
            "Another device edited this project. We kept the latest version; the other copy is saved as a sidecar."
        )
    }

    func test_conflictDiffTitle_matches_locked_string_with_em_dash() {
        XCTAssertEqual(LockedCopy.conflictDiffTitle, "Conflict \u{2014} read-only diff")
        XCTAssertTrue(LockedCopy.conflictDiffTitle.contains("\u{2014}"))
    }

    func test_imageNoLongerAvailable_matches_locked_string() {
        XCTAssertEqual(
            LockedCopy.imageNoLongerAvailable,
            "This frame is no longer available. Return to the project."
        )
    }

    func test_icloudWaitingBanner_matches_locked_string_with_em_dash() {
        XCTAssertEqual(LockedCopy.icloudWaitingBanner, "Waiting for iCloud \u{2014} pull to retry.")
        XCTAssertTrue(LockedCopy.icloudWaitingBanner.contains("\u{2014}"))
    }

    func test_projectFullAthleteCap_matches_locked_string_with_em_dash() {
        XCTAssertEqual(LockedCopy.projectFullAthleteCap, "Project full \u{2014} 8 athletes max.")
        XCTAssertTrue(LockedCopy.projectFullAthleteCap.contains("\u{2014}"))
    }

    func test_instanceListEmptyState_matches_locked_string() {
        XCTAssertEqual(
            LockedCopy.instanceListEmptyState,
            "No boxes yet. Tap Box and drag on the image."
        )
    }
}
