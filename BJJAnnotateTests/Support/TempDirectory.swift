import Foundation

/// Real on-disk temporary directory that auto-cleans on deinit.
///
/// AIP §6.1 (no `FileManager` mocks): every persistence test uses a real temp
/// directory so we exercise the OS-level APIs we depend on (security-scoped
/// bookmarks, `contentsOfDirectory`, `attributesOfItem`).
final class TempDirectory {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("BJJAnnotateTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base
    }

    @discardableResult
    func makeFile(named name: String, contents: Data = Data([0x00])) throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        try contents.write(to: fileURL)
        return fileURL
    }

    @discardableResult
    func makeSubdirectory(named name: String) throws -> URL {
        let subURL = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: subURL, withIntermediateDirectories: true)
        return subURL
    }

    /// Rename the temp directory in place. Used to verify bookmark
    /// resolution still returns the new `lastPathComponent` (PM AC #6).
    func rename(to newName: String) throws -> URL {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
        try FileManager.default.moveItem(at: url, to: newURL)
        return newURL
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
