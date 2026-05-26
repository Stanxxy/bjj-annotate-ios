import Foundation

/// PM-locked copy strings. DO NOT edit without PM sign-off.
///
/// Sources: `working_log/knowledge-base/scratch/2026-05-25-bjj-annotate-ios-phase-0-acceptance.md`
/// (§Scope Boundaries, Locked PM-owned strings) + Designer pack §Section 4 (MUST honor exactly).
///
/// Em-dashes are U+2014 (Unicode EM DASH). NOT a hyphen (U+002D) nor a minus (U+2212).
/// `LockedCopyTests` enforces this invariant.
enum LockedCopy {
    /// Shown on `RootView` when `BookmarkStore` is empty.
    static let emptyProjectList =
        "No projects yet. Tap Open Folder to pick an iCloud Drive folder of BJJ frames."

    /// Inline row title when a saved project's folder cannot be resolved.
    /// Tapping invokes the folder picker so the user can relocate the project.
    /// Em-dash is U+2014.
    static let bookmarkErrorRow =
        "Folder not found \u{2014} tap to relocate"

    /// Shown on `ProjectGridView` when the resolved folder contains no images.
    static let emptyProjectGrid =
        "This folder has no images yet. Drop .jpg, .png, or .heic files into the folder in Files and pull to refresh."
}
