import XCTest
@testable import BJJAnnotate

/// Enforces PM-locked copy invariants. See `LockedCopy.swift` for source-of-truth pointers.
final class LockedCopyTests: XCTestCase {

    func test_emptyProjectList_matches_PM_locked_string_byte_for_byte() {
        XCTAssertEqual(
            LockedCopy.emptyProjectList,
            "No projects yet. Tap Open Folder to pick an iCloud Drive folder of BJJ frames."
        )
    }

    func test_bookmarkErrorRow_matches_PM_locked_string_byte_for_byte() {
        // Em-dash is U+2014. If this assertion fails after a copy-paste, autocorrect ate the em-dash.
        XCTAssertEqual(
            LockedCopy.bookmarkErrorRow,
            "Folder not found \u{2014} tap to relocate"
        )
    }

    func test_bookmarkErrorRow_contains_em_dash_U2014_and_not_hyphen() {
        // Explicit guard for the most common regression vector.
        XCTAssertTrue(
            LockedCopy.bookmarkErrorRow.contains("\u{2014}"),
            "bookmarkErrorRow must contain U+2014 EM DASH; saw: \(LockedCopy.bookmarkErrorRow)"
        )
        XCTAssertFalse(
            LockedCopy.bookmarkErrorRow.contains(" - "),
            "bookmarkErrorRow must use em-dash, not ASCII hyphen-minus surrounded by spaces."
        )
    }

    func test_emptyProjectGrid_matches_PM_locked_string_byte_for_byte() {
        XCTAssertEqual(
            LockedCopy.emptyProjectGrid,
            "This folder has no images yet. Drop .jpg, .png, or .heic files into the folder in Files and pull to refresh."
        )
    }
}
