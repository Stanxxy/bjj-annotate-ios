import XCTest

/// Locked-copy grep gate. AC enforcement: every PM-locked string must live in
/// `BJJAnnotate/App/LockedCopy.swift` and nowhere else (including no duplicate
/// hard-coded literal in views, view models, or persistence). If a future contributor
/// inlines `"Gi"` or `"+ New athlete"` instead of routing through `LockedCopy`, this
/// test fails and the build is red.
///
/// The gate walks the on-disk source tree to find Swift files (excluding `LockedCopy.swift`
/// itself and test bundles). The tree root is derived from `#file` at build time so the
/// test works regardless of where the simulator unpacks the bundle.
final class LockedCopyGrepTests: XCTestCase {

    /// Path-strings that must NEVER appear in any production source file outside
    /// `LockedCopy.swift`. We grep for the exact bytes including em-dashes (U+2014).
    private static let forbiddenLiterals: [String] = [
        // Phase 0 strings (already gated by Phase 0; re-asserted for completeness).
        "Folder not found \u{2014} tap to relocate",
        // Phase 1 strings.
        "Keypoints \u{2014} Phase 2",
        "+ New athlete",
        "Box too small \u{2014} drag a larger area.",
        "Another device edited this project. We kept the latest version; the other copy is saved as a sidecar.",
        "Conflict \u{2014} read-only diff",
        "This frame is no longer available. Return to the project.",
        "Waiting for iCloud \u{2014} pull to retry.",
        "Project full \u{2014} 8 athletes max.",
        "No boxes yet. Tap Box and drag on the image.",
    ]

    func test_no_locked_string_appears_in_non_LockedCopy_files() throws {
        let root = Self.repoRoot()
        let production = root.appendingPathComponent("BJJAnnotate", isDirectory: true)
        var offenders: [(file: URL, literal: String)] = []
        try enumerateSwiftFiles(under: production) { url in
            // Skip the source-of-truth file itself.
            if url.lastPathComponent == "LockedCopy.swift" { return }
            let body = try String(contentsOf: url, encoding: .utf8)
            for literal in Self.forbiddenLiterals where body.contains(literal) {
                offenders.append((url, literal))
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "Locked PM-copy strings must live ONLY in LockedCopy.swift. Offenders:\n" +
            offenders.map { "  - \($0.literal) in \($0.file.path)" }.joined(separator: "\n")
        )
    }

    // MARK: - Helpers

    /// Repo root derived from `#file` (this test's source path), walking up to the
    /// `bjj-annotate-ios/` directory. Works whether the test bundle was unpacked into
    /// DerivedData or run via `xcodebuild test`.
    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" && url.lastPathComponent != "bjj-annotate-ios" {
            url.deleteLastPathComponent()
        }
        return url
    }

    private func enumerateSwiftFiles(under root: URL, visit: (URL) throws -> Void) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in enumerator {
            let attrs = try url.resourceValues(forKeys: [.isDirectoryKey])
            if attrs.isDirectory == true { continue }
            guard url.pathExtension == "swift" else { continue }
            try visit(url)
        }
    }
}
