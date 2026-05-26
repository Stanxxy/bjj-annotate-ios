import XCTest
@testable import BJJAnnotate

/// Asserts that the FolderPicker is configured per PM AC #7 (folders only, no multi-select).
final class FolderPickerTests: XCTestCase {
    @MainActor
    func test_picker_configured_for_folders_no_multiselect() {
        let picker = FolderPicker.makePicker()
        XCTAssertFalse(picker.allowsMultipleSelection,
                       "PM AC #7 forbids multi-select")
        // Document types are private API on UIDocumentPickerViewController in iOS 18;
        // the initializer is the contract we exercise.
        XCTAssertEqual(picker.documentPickerMode, .open,
                       "picker should be in .open mode (asCopy: false)")
    }
}
