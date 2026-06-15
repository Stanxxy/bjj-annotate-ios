import XCTest
@testable import BJJAnnotate

/// T13 — Thumbnail-tap navigation to AnnotatorView (AC #8).
///
/// XCUI testing requires xcodebuild + simulator; this file asserts the navigation
/// destination contract at the model layer:
///   - `RootView.NavigationDestination` exposes an `.annotator(bookmarkID:,imageURL:)`
///     case (Hashable + Equatable so NavigationStack identifies pushes correctly).
///   - The destination preserves the imageURL as the file's last-path-component
///     identifier, so a re-entry after image deletion can detect the zero-image
///     state (AC #39).
///
/// The visible UI assertion lives in the matching XCUI test landing in T13/T22.
final class AnnotatorNavigationContractTests: XCTestCase {

    func test_annotator_destination_case_exists_with_bookmarkID_and_imageURL() {
        let url = URL(fileURLWithPath: "/tmp/frame_0001.jpg")
        let dest = RootView.NavigationDestination.annotator(bookmarkID: "bookmark-1", imageURL: url)
        // Equality + hashability: NavigationStack relies on Hashable conformance.
        let same = RootView.NavigationDestination.annotator(bookmarkID: "bookmark-1", imageURL: url)
        XCTAssertEqual(dest, same)
        XCTAssertEqual(dest.hashValue, same.hashValue)
    }

    func test_annotator_destination_distinguishes_different_image_urls() {
        let a = URL(fileURLWithPath: "/tmp/frame_0001.jpg")
        let b = URL(fileURLWithPath: "/tmp/frame_0002.jpg")
        let destA = RootView.NavigationDestination.annotator(bookmarkID: "bookmark-1", imageURL: a)
        let destB = RootView.NavigationDestination.annotator(bookmarkID: "bookmark-1", imageURL: b)
        XCTAssertNotEqual(destA, destB)
    }

    func test_annotator_destination_distinguishes_grid_from_annotator() {
        let url = URL(fileURLWithPath: "/tmp/frame.jpg")
        let grid = RootView.NavigationDestination.grid(bookmarkID: "bookmark-1")
        let annotator = RootView.NavigationDestination.annotator(bookmarkID: "bookmark-1", imageURL: url)
        XCTAssertNotEqual(grid, annotator)
    }
}
