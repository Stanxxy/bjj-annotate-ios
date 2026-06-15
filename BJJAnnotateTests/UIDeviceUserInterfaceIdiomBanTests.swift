import XCTest

/// Evaluator pre-emption R-UI-1: BAN `UIDevice.current.userInterfaceIdiom` in
/// production SwiftUI code.
///
/// Reasoning (from the Phase 1 evaluation report): UIKit's idiom-flag-based
/// branching does NOT track the actual size class at runtime — on iPad in
/// Slide Over / Split View at compact width, `userInterfaceIdiom == .pad` but
/// the size class is `.compact`. We need the size-class signal, NOT the device
/// signal. Use `@Environment(\.horizontalSizeClass)` (production wrapper lives
/// in `BJJAnnotate/Features/Layout.swift`).
///
/// This is a CI grep gate. Fails the build if any production source under
/// `BJJAnnotate/` references the banned API. The gate is permanent; do not
/// soften.
final class UIDeviceUserInterfaceIdiomBanTests: XCTestCase {

    private static let bannedSubstrings: [String] = [
        "UIDevice.current.userInterfaceIdiom",
        "userInterfaceIdiom ==",
        "userInterfaceIdiom !=",
    ]

    func test_no_UIDevice_userInterfaceIdiom_branch_in_production() throws {
        let root = Self.repoRoot()
        let production = root.appendingPathComponent("BJJAnnotate", isDirectory: true)
        var offenders: [(URL, String)] = []
        try enumerateSwiftFiles(under: production) { url in
            // The Layout helper itself documents the rule; check its body for the API
            // anyway — the doc comment uses the constant name through string-escaping
            // so the grep won't catch the docs.
            let body = try String(contentsOf: url, encoding: .utf8)
            for s in Self.bannedSubstrings where body.contains(s) {
                offenders.append((url, s))
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "UIDevice.userInterfaceIdiom branching is banned (R-UI-1). " +
            "Use @Environment(\\.horizontalSizeClass) via Layout helper. Offenders:\n" +
            offenders.map { "  - \($0.1) in \($0.0.path)" }.joined(separator: "\n")
        )
    }

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
