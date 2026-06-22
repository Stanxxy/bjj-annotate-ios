import XCTest
import Observation
@testable import BJJAnnotate

/// `AnnotationStore` is the @Observable single-source-of-truth for box mutations.
/// AIP §3 (Marker C): UI state synchronous; file I/O is debounced separately
/// (covered by CocoFileCoordinatorDebounceTests in T9).
///
/// These tests use a no-op scheduler (`SilentScheduler`) so the store can be
/// exercised independently of disk I/O. The scheduler conforms to the same
/// protocol the production CocoFileCoordinator implements (T8/T9).
@MainActor
final class AnnotationStoreTests: XCTestCase {

    // MARK: - Fixtures

    private static let imageId = 1

    private func makeStore(athletes: [Athlete] = [], stickyCategoryId: Int? = nil) -> AnnotationStore {
        let meta = BjjAnnotateMeta(
            schema_version: 1,
            athletes: athletes,
            image_states: [],
            settings: MetaSettings(sticky_category_id: stickyCategoryId ?? 1)
        )
        let doc = CocoDocument(
            info: nil,
            images: [CocoImage(id: Self.imageId, file_name: "frame_0001.jpg", width: 1920, height: 1080)],
            categories: AnnotationStoreTests.bjjCategories(),
            annotations: [],
            bjj_annotate_meta: meta
        )
        return AnnotationStore(initial: doc, imageId: Self.imageId, scheduler: SilentScheduler())
    }

    private static func bjjCategories() -> [CocoCategory] {
        return [
            CocoCategory(id: 1, name: "gi-athlete", supercategory: "person", keypoints: [], skeleton: []),
            CocoCategory(id: 2, name: "nogi-athlete", supercategory: "person", keypoints: [], skeleton: []),
            CocoCategory(id: 3, name: "referee", supercategory: "person", keypoints: nil, skeleton: nil),
        ]
    }

    private func aBox() -> BBoxIntent {
        BBoxIntent(rect: BBox(x: 100, y: 100, w: 200, h: 200))
    }

    // MARK: - AC #4 — exactly ONE observation invalidation per mutation

    func test_upsertBox_emits_exactly_one_observation_invalidation() {
        assertExactlyOneInvalidation { store in
            store.upsertBox(self.aBox())
        }
    }

    func test_setClass_emits_exactly_one_observation_invalidation() {
        let store = makeStore()
        let id = store.upsertBox(aBox())
        assertExactlyOneInvalidation(using: store) { store in
            store.setClass(instanceId: id, category: .nogi)
        }
    }

    func test_setAthleteId_emits_exactly_one_observation_invalidation() {
        let store = makeStore(athletes: [
            Athlete(id: "athlete-1", display_name: "athlete-1", color_hex: "#3B82F6"),
            Athlete(id: "athlete-2", display_name: "athlete-2", color_hex: "#F59E0B"),
        ])
        let id = store.upsertBox(aBox())
        assertExactlyOneInvalidation(using: store) { store in
            store.setAthleteId(instanceId: id, athleteId: "athlete-2")
        }
    }

    func test_deleteInstance_emits_exactly_one_observation_invalidation() {
        let store = makeStore()
        let id = store.upsertBox(aBox())
        assertExactlyOneInvalidation(using: store) { store in
            store.deleteInstance(instanceId: id)
        }
    }

    private func assertExactlyOneInvalidation(
        using providedStore: AnnotationStore? = nil,
        _ action: (AnnotationStore) -> Void,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let store = providedStore ?? makeStore()
        let invalidationCount = Locked<Int>(0)
        withObservationTracking {
            _ = store.coco
        } onChange: {
            invalidationCount.increment()
        }
        action(store)
        // Observation onChange is dispatched asynchronously to the main run loop.
        let exp = XCTestExpectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(invalidationCount.value, 1, "expected exactly 1 invalidation", file: file, line: line)
    }

    // MARK: - AC #16 / #17 — first box defaults + auto-assigned athlete

    func test_first_ever_box_defaults_to_gi_athlete_category_1() {
        // PM AC #17: sticky absent → default 1 (gi-athlete).
        let store = makeStore(stickyCategoryId: 1)
        let id = store.upsertBox(aBox())
        let ann = store.coco.annotations.first { $0.id == id }
        XCTAssertEqual(ann?.category_id, 1)
    }

    func test_new_box_assigns_sticky_category_and_next_free_athlete_id_with_user_source() {
        let store = makeStore(stickyCategoryId: 2) // NoGi
        let id = store.upsertBox(aBox())
        guard let ann = store.coco.annotations.first(where: { $0.id == id }) else {
            return XCTFail("Annotation not created")
        }
        XCTAssertEqual(ann.category_id, 2)
        XCTAssertEqual(ann.attributes.athlete_id, "athlete-1")
        XCTAssertEqual(ann.attributes.source, "user")
        // Athlete dictionary updated.
        XCTAssertEqual(store.coco.bjj_annotate_meta?.athletes.first?.id, "athlete-1")
    }

    func test_new_box_does_not_set_model_version_attribute() {
        let store = makeStore()
        let id = store.upsertBox(aBox())
        let ann = store.coco.annotations.first { $0.id == id }
        XCTAssertNil(ann?.attributes.model_version, "model_version must be ABSENT on user boxes (AC #16d)")
    }

    // MARK: - AC #21 / Marker D — class change preserves athlete-id; sticky updates

    func test_class_change_updates_box_category_sticky_category_preserves_athlete_id() {
        let store = makeStore(stickyCategoryId: 1) // Gi
        let id = store.upsertBox(aBox())
        XCTAssertEqual(store.coco.annotations.first?.attributes.athlete_id, "athlete-1")

        store.setClass(instanceId: id, category: .nogi)

        let ann = store.coco.annotations.first { $0.id == id }
        XCTAssertEqual(ann?.category_id, 2, "category updated")
        XCTAssertEqual(ann?.attributes.athlete_id, "athlete-1", "athlete-id preserved across class change")
        XCTAssertEqual(store.coco.bjj_annotate_meta?.settings.sticky_category_id, 2, "sticky updated")
    }

    // MARK: - Addendum #1 — Ref → Gi auto-binds next free athlete-id

    func test_reclass_from_ref_to_gi_auto_binds_next_free_athlete_id() {
        let store = makeStore(stickyCategoryId: 3) // Ref
        let id = store.upsertBox(aBox())
        let initial = store.coco.annotations.first { $0.id == id }
        XCTAssertNil(initial?.attributes.athlete_id, "referee box has no athlete_id")

        store.setClass(instanceId: id, category: .gi)

        let after = store.coco.annotations.first { $0.id == id }
        XCTAssertEqual(after?.category_id, 1)
        XCTAssertEqual(after?.attributes.athlete_id, "athlete-1", "Ref→Gi auto-binds next free id (Addendum #1)")
    }

    // MARK: - AC #13 — delete instance keeps athlete dictionary entry

    func test_deleteInstance_keeps_athlete_dictionary_entry() {
        let store = makeStore()
        let id = store.upsertBox(aBox())
        XCTAssertEqual(store.coco.bjj_annotate_meta?.athletes.count, 1)
        store.deleteInstance(instanceId: id)
        XCTAssertTrue(store.coco.annotations.isEmpty, "annotation removed")
        XCTAssertEqual(store.coco.bjj_annotate_meta?.athletes.count, 1,
                       "athlete dictionary entry preserved across delete (AC #13 / Marker B)")
    }
}

/// Thread-safe counter for `withObservationTracking` onChange callbacks (the
/// callback may run on any executor).
private final class Locked<T: Numeric> {
    private var _value: T
    private let lock = NSLock()
    init(_ initial: T) { _value = initial }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() where T == Int {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}

/// Single-source-of-truth grep gate (AC #5): no secondary annotation representation.
final class DomainSingleSourceGrepTests: XCTestCase {

    func test_no_secondary_annotation_struct_exists() throws {
        let root = Self.repoRoot()
        let production = root.appendingPathComponent("BJJAnnotate", isDirectory: true)
        let forbidden = ["InternalAnnotation", "DraftAnnotation", "WorkingAnnotation",
                         "LocalAnnotation", "ExportableCoco"]
        var offenders: [(file: URL, symbol: String)] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: production, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in enumerator {
            let attrs = try url.resourceValues(forKeys: [.isDirectoryKey])
            if attrs.isDirectory == true { continue }
            guard url.pathExtension == "swift" else { continue }
            let body = try String(contentsOf: url, encoding: .utf8)
            for sym in forbidden where body.contains(sym) {
                offenders.append((url, sym))
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "AnnotationStore.coco is the ONLY annotation representation (AC #5). Offenders:\n" +
            offenders.map { "  - \($0.symbol) in \($0.file.path)" }.joined(separator: "\n")
        )
    }

    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #file)
        while url.path != "/" && url.lastPathComponent != "bjj-annotate-ios" {
            url.deleteLastPathComponent()
        }
        return url
    }
}
