import Foundation

/// PM-locked copy strings. DO NOT edit without PM sign-off.
///
/// Phase 0 sources: `working_log/knowledge-base/scratch/2026-05-25-bjj-annotate-ios-phase-0-acceptance.md`
/// (§Scope Boundaries, Locked PM-owned strings) + Designer pack §Section 4.
///
/// Phase 1 sources: `working_log/knowledge-base/scratch/2026-06-14-bjj-annotate-ios-phase-1-acceptance.md`
/// §Locked PM-owned strings (9 strings) + §PM Addendum §10 (athlete cap) +
/// §PM Addendum Designer Resolutions §3 (instance-list empty state). 11 Phase 1 strings total.
///
/// Em-dashes are U+2014 (Unicode EM DASH). NOT a hyphen (U+002D) nor a minus (U+2212).
/// `LockedCopyTests` + `Phase1LockedCopyTests` enforce this invariant byte-for-byte.
/// `LockedCopyGrepTests` enforces these strings appear ONLY in this file.
enum LockedCopy {

    // MARK: - Phase 0

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

    // MARK: - Phase 1

    /// Long-press tooltip on the disabled Keypoints tool slot. (AC #9 / Designer §9.)
    static let keypointsDisabledTooltip =
        "Keypoints \u{2014} Phase 2"

    /// "+ New athlete" picker row label. (AC #11 / Designer §3.4.)
    static let newAthleteRow =
        "+ New athlete"

    /// Toast on sub-4px drag rejection. (AC #20 / Designer §7.)
    static let boxTooSmallToast =
        "Box too small \u{2014} drag a larger area."

    /// Class chip label for `gi-athlete` (category_id 1). (AC #10.)
    static let classChipGi = "Gi"

    /// Class chip label for `nogi-athlete` (category_id 2).
    static let classChipNoGi = "NoGi"

    /// Class chip label for `referee` (category_id 3).
    static let classChipRef = "Ref"

    /// Athlete picker row format. (AC #11 / Designer §3.3.) Integer id; no leading zero
    /// or padding. Phase 1 has no display-name editing; the label IS the id.
    static func athleteRow(id: Int) -> String { "athlete-\(id)" }

    /// Non-blocking conflict banner copy. (AC #34 / Designer §6.2.) No em-dashes.
    static let conflictBanner =
        "Another device edited this project. We kept the latest version; the other copy is saved as a sidecar."

    /// Read-only diff modal title. (AC #35 / Designer §6.3.) Em-dash U+2014.
    static let conflictDiffTitle =
        "Conflict \u{2014} read-only diff"

    /// Empty-folder annotator copy (image deleted while app was suspended). (AC #39.)
    static let imageNoLongerAvailable =
        "This frame is no longer available. Return to the project."

    /// iCloud materialization timeout banner. (AC #30 / Designer §8.) Em-dash U+2014.
    static let icloudWaitingBanner =
        "Waiting for iCloud \u{2014} pull to retry."

    /// Athlete cap reached — replaces `+ New athlete` row when 8 athletes allocated.
    /// (PM addendum #10 / Designer §3.1.) Em-dash U+2014.
    static let projectFullAthleteCap =
        "Project full \u{2014} 8 athletes max."

    /// Instance-list empty state. (PM addendum Designer Resolutions §3 / Designer §5.4.)
    static let instanceListEmptyState =
        "No boxes yet. Tap Box and drag on the image."
}
