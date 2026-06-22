import XCTest
@testable import BJJAnnotate

/// T22 — Zero-image annotator state + Back action.
///
/// AC #39 (Designer §1.5): if the user navigates into the annotator and the
/// image was deleted while the app was suspended, the surface shows the locked
/// "no longer available" copy + a Back action that pops back to the project
/// grid.
///
/// `AnnotatorImagePresence` is the pure decision helper that the view uses to
/// branch between `.imagePresent` and `.missing`. Asserts both states + the
/// locked copy.
final class AnnotatorImagePresenceTests: XCTestCase {

    func test_existing_file_reports_imagePresent() throws {
        let temp = try TempDirectory()
        let url = try temp.makeFile(named: "frame.jpg", contents: Data([0x00]))
        let presence = AnnotatorImagePresence.evaluate(imageURL: url)
        XCTAssertEqual(presence, .imagePresent)
    }

    func test_missing_file_reports_missing_with_locked_copy() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("never_created.jpg")
        let presence = AnnotatorImagePresence.evaluate(imageURL: url)
        XCTAssertEqual(presence, .missing)
        XCTAssertEqual(AnnotatorImagePresence.missingCopy, LockedCopy.imageNoLongerAvailable)
    }
}
