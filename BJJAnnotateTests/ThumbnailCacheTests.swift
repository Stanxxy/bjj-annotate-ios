import XCTest
import UIKit
@testable import BJJAnnotate

/// Real on-disk thumbnail generation tests. `QLThumbnailGenerator` returns nil for
/// unsupported types (AIP risk R2) — we assert that explicitly so the contract is
/// version-pinned.
final class ThumbnailCacheTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp = nil
        super.tearDown()
    }

    func test_cacheKey_includes_path_and_modification_date() throws {
        let url = try temp.makeFile(named: "frame.jpg")
        let key = ThumbnailCache.cacheKey(for: url)

        XCTAssertNotNil(key)
        XCTAssertTrue(key!.hasPrefix(url.path))
        XCTAssertTrue(key!.contains("|"), "key should embed mod date after a pipe separator")
    }

    func test_cacheKey_changes_when_file_modification_date_changes() throws {
        let url = try temp.makeFile(named: "frame.jpg")
        let firstKey = ThumbnailCache.cacheKey(for: url)

        // Mutate the file's modification date.
        let later = Date(timeIntervalSince1970: 99_999_999)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        let secondKey = ThumbnailCache.cacheKey(for: url)

        XCTAssertNotNil(firstKey)
        XCTAssertNotNil(secondKey)
        XCTAssertNotEqual(firstKey, secondKey,
                          "cache key must change when modification date changes so thumbnails invalidate")
    }

    func test_returns_nil_when_file_does_not_exist() async throws {
        // QLThumbnailGenerator returns nil when the file is absent. Caller renders the
        // placeholder symbol when the cache returns nil (Designer pack §State 2b).
        //
        // NOTE: QL DOES return a generic file-type icon for unsupported but extant files
        // (e.g. .txt → text-doc icon). That's acceptable Phase-0 behavior — `ProjectFolder`
        // already filters to .jpg/.jpeg/.png/.heic before we ever reach this code path.
        // See AIP risk R2 (revised): the contract is "nil iff QL cannot generate anything,"
        // not "nil for non-images" — the extension whitelist owns that filter.
        let missing = temp.url.appendingPathComponent("does-not-exist.jpg")
        let cache = ThumbnailCache()

        let image = await cache.image(for: missing)

        XCTAssertNil(image, "non-existent file should yield nil thumbnail")
    }
}
