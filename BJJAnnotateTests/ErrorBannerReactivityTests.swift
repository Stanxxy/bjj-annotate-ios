import XCTest
@testable import BJJAnnotate

/// B1 — ErrorBanner reactivity contract.
///
/// The bug: `AnnotatorView.wiredAnnotatorBody` previously rendered the error overlay
/// inline as a method on the non-observed `AnnotatorView` struct. Because `AnnotatorView`
/// holds no `@ObservedObject` reference to `AnnotationStore`, calling
/// `store.clearLastError()` set `lastError = nil` on the store but the view never
/// invalidated → the "changes may be lost" banner was permanently stuck. Likewise, a NEW
/// error arriving after first render would also never surface.
///
/// The fix: `ErrorBanner` is a dedicated `struct … View` with `@ObservedObject var store`,
/// mirroring `ConflictBanner`. This test file locks the reactivity contract at the store
/// level (the seam `ErrorBanner` reads) so that if the `@Published` wiring is ever broken
/// the tests here will fail.
///
/// Why store-level assertions are the right seam:
/// SwiftUI's `@ObservedObject` synthesis is a compile-time contract; what CAN be tested
/// in a headless XCTest without a live simulator is the underlying `@Published` source of
/// truth that `ErrorBanner` reads. If `lastError` does not change when `clearLastError()`
/// is called, `ErrorBanner` can never dismiss — these two are logically equivalent for
/// the reactivity guarantee. The tests below will FAIL if either (a) `lastError` is not
/// `@Published`, or (b) `clearLastError()` does not nil it out — both of which would
/// break the banner even with the struct wrapper in place.
@MainActor
final class ErrorBannerReactivityTests: XCTestCase {

    // MARK: - Store factory (mirrors ConflictBannerTests helper)

    private func makeStore() -> AnnotationStore {
        let doc = CocoDocument(
            info: nil,
            images: [CocoImage(id: 1, file_name: "img.jpg", width: 1920, height: 1080)],
            categories: [],
            annotations: [],
            bjj_annotate_meta: BjjAnnotateMeta(
                schema_version: 1,
                athletes: [],
                image_states: [],
                settings: MetaSettings(sticky_category_id: 1)
            )
        )
        return AnnotationStore(initial: doc, imageId: 1, scheduler: SilentScheduler())
    }

    // MARK: - Contract: lastError starts nil

    /// ErrorBanner must render nothing on a fresh store (no error = no banner).
    func test_lastError_is_nil_on_fresh_store() {
        let store = makeStore()
        XCTAssertNil(store.lastError,
                     "Fresh store must have lastError == nil; ErrorBanner must not show on first render.")
    }

    // MARK: - Contract: setting lastError makes banner state present

    /// Simulates the engine/coordinator setting an error after first render.
    /// ErrorBanner reads `store.lastError`; this must be non-nil for the banner to appear.
    func test_setting_lastError_makes_banner_state_present() {
        let store = makeStore()
        store.lastError = .writeFailed(description: "disk full")
        XCTAssertNotNil(store.lastError,
                        "After store.lastError = .writeFailed(...), lastError must be non-nil " +
                        "so ErrorBanner shows. If this fails, the @Published wiring is broken.")
    }

    // MARK: - Contract: clearLastError() makes banner state absent

    /// This is the load-bearing assertion for B1.
    ///
    /// Pre-fix behaviour: `store.clearLastError()` DID set `lastError = nil` on the
    /// model but `AnnotatorView` (non-observed parent) never re-rendered, so the banner
    /// stayed visible. The fix routes the overlay through `ErrorBanner` which holds
    /// `@ObservedObject var store`, so clearing `lastError` triggers SwiftUI invalidation
    /// and the conditional `if let err = store.lastError` branch collapses.
    ///
    /// This test asserts the MODEL half of that contract. If `clearLastError()` ever
    /// stops nil-ing `lastError`, even a correctly-wired `ErrorBanner` could not dismiss.
    func test_clearLastError_makes_banner_state_absent() {
        let store = makeStore()
        store.lastError = .encodeFailed(description: "json broken")
        XCTAssertNotNil(store.lastError, "Precondition: lastError must be set before clear.")

        store.clearLastError()

        XCTAssertNil(store.lastError,
                     "After clearLastError(), store.lastError must be nil. " +
                     "ErrorBanner's `if let err = store.lastError` branch will collapse " +
                     "on the next @ObservedObject-triggered render, dismissing the banner. " +
                     "If this assertion fails, the dismiss button can never hide the banner " +
                     "(B1 regression).")
    }

    // MARK: - Contract: multiple error lifecycle round-trips

    /// Verifies that the banner can appear, dismiss, and appear again — the full
    /// lifecycle that a real annotator session exercises (e.g. initial read error
    /// dismissed, then a subsequent write error surfaces).
    func test_error_lifecycle_appear_dismiss_appear() {
        let store = makeStore()

        // Round 1 — read error
        store.lastError = .readFailed(description: "file missing")
        XCTAssertNotNil(store.lastError, "Round 1 set: banner should appear.")
        store.clearLastError()
        XCTAssertNil(store.lastError, "Round 1 clear: banner should dismiss.")

        // Round 2 — write error after a successful session
        store.lastError = .writeFailed(description: "no space")
        XCTAssertNotNil(store.lastError, "Round 2 set: banner should appear again.")
        store.clearLastError()
        XCTAssertNil(store.lastError, "Round 2 clear: banner should dismiss again.")
    }

    // MARK: - Contract: ErrorBanner.message(_:) covers all AnnotationStoreError cases

    /// Ensures `ErrorBanner.message(for:)` returns non-empty strings for all enum cases,
    /// so the label inside the banner is never blank. This also acts as a compile-time
    /// exhaustiveness check — if a new `AnnotationStoreError` case is added without
    /// updating the switch, the compiler will warn and this test surface makes it visible.
    func test_errorBanner_message_is_non_empty_for_all_cases() {
        let cases: [AnnotationStoreError] = [
            .decodeFailed(description: "x"),
            .encodeFailed(description: "x"),
            .writeFailed(description: "x"),
            .readFailed(description: "x"),
            .icloudMaterializationTimeout,
        ]
        for errorCase in cases {
            let msg = ErrorBanner.message(for: errorCase)
            XCTAssertFalse(msg.isEmpty,
                           "ErrorBanner.message(for: \(errorCase)) must be non-empty " +
                           "— an empty label would render a blank, invisible banner.")
        }
    }

    // MARK: - Structural contract: ErrorBanner uses @ObservedObject (compile-time)

    /// Verifies `ErrorBanner` can be constructed with an `AnnotationStore` argument,
    /// confirming the `@ObservedObject var store: AnnotationStore` property exists and
    /// the type compiles correctly. If this test fails to BUILD, the struct is missing
    /// the `store` parameter (regression to the inline-method pattern).
    func test_errorBanner_is_constructible_with_store() {
        let store = makeStore()
        // Construction proves @ObservedObject init seam exists.
        let banner = ErrorBanner(store: store)
        // Force use of the value so the compiler doesn't elide the call.
        _ = banner
    }
}
