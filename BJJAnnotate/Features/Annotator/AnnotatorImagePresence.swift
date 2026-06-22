import Foundation

/// T22 — Pure presence decision for `AnnotatorView`.
///
/// AC #39: when the user navigates into the annotator and the image was
/// deleted while the app was suspended, the view shows the locked
/// "no longer available" copy + a Back action. This enum encodes the two
/// states; the view branches on the result.
enum AnnotatorImagePresence: Equatable {
    case imagePresent
    case missing

    /// File-presence check at the given URL.
    static func evaluate(imageURL: URL) -> AnnotatorImagePresence {
        return FileManager.default.fileExists(atPath: imageURL.path) ? .imagePresent : .missing
    }

    /// Locked copy for the `.missing` state.
    static var missingCopy: String { LockedCopy.imageNoLongerAvailable }
}
