import Foundation

/// Scans a project folder for image files at the root level only.
///
/// PM AC #10: `.jpg/.jpeg/.png/.heic` only (case-insensitive); subdirectories are NOT recursed;
/// directories (notably `.mlpackage`) are excluded even though the extension whitelist is
/// strict (defense-in-depth — covers e.g. a hypothetical `foo.jpg` directory).
struct ProjectFolder {
    let url: URL

    /// Accepted file extensions, lowercased. Exactly the four PM AC #10 calls out.
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]

    init(url: URL) {
        self.url = url
    }

    /// Returns image URLs at the root of the folder, sorted ascending by filename
    /// (case-insensitive — matches Files.app + Photos.app behavior).
    func scanImages() throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let items = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return items
            .filter { Self.isImageFile($0) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func isImageFile(_ url: URL) -> Bool {
        // Exclude directories (covers .mlpackage and any other bundle / directory the user
        // dropped into the folder). Two-layer guard: directory check first, extension whitelist
        // second.
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true { return false }
        return imageExtensions.contains(url.pathExtension.lowercased())
    }
}
