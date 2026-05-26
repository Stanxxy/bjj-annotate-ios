import XCTest
@testable import BJJAnnotate

/// Real on-disk scan tests; NO `FileManager` mocks (AIP §6.1, evaluator gate).
final class ProjectFolderTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp = nil
        super.tearDown()
    }

    func test_scans_jpg_png_heic_sorted_case_insensitive_excludes_others() throws {
        try temp.makeFile(named: "b.jpg")
        try temp.makeFile(named: "a.png")
        try temp.makeFile(named: "c.HEIC")
        try temp.makeFile(named: "d.jpeg")
        try temp.makeFile(named: "ignored.txt")
        try temp.makeFile(named: "annotations.json")

        let folder = ProjectFolder(url: temp.url)
        let names = try folder.scanImages().map(\.lastPathComponent)

        XCTAssertEqual(names, ["a.png", "b.jpg", "c.HEIC", "d.jpeg"])
    }

    func test_subdirectories_not_recursed() throws {
        let sub = try temp.makeSubdirectory(named: "models")
        FileManager.default.createFile(atPath: sub.appendingPathComponent("buried.jpg").path,
                                        contents: Data([0x00]))
        try temp.makeFile(named: "top.jpg")

        let names = try ProjectFolder(url: temp.url).scanImages().map(\.lastPathComponent)

        XCTAssertEqual(names, ["top.jpg"], "nested image should not appear; subdirectories not recursed")
    }

    func test_mlpackage_directory_excluded_from_scan() throws {
        // .mlpackage is a directory bundle — the directory filter catches it even if
        // someone tries to match it via extension shenanigans.
        try temp.makeSubdirectory(named: "models")
        try temp.makeSubdirectory(named: "yolo26-pose.mlpackage")
        try temp.makeFile(named: "real.jpg")

        let names = try ProjectFolder(url: temp.url).scanImages().map(\.lastPathComponent)

        XCTAssertEqual(names, ["real.jpg"])
    }

    func test_hidden_files_excluded() throws {
        try temp.makeFile(named: ".DS_Store")
        try temp.makeFile(named: "visible.jpg")

        let names = try ProjectFolder(url: temp.url).scanImages().map(\.lastPathComponent)

        XCTAssertEqual(names, ["visible.jpg"])
    }

    func test_empty_folder_returns_empty_array() throws {
        XCTAssertEqual(try ProjectFolder(url: temp.url).scanImages(), [])
    }

    func test_throws_when_folder_does_not_exist() throws {
        let missing = temp.url.appendingPathComponent("does-not-exist")
        XCTAssertThrowsError(try ProjectFolder(url: missing).scanImages())
    }
}
