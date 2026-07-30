import Foundation

/// Writes pasted/dropped images into an Assets folder and computes the
/// relative Markdown link from the note to the asset.
enum AssetStore {
    /// Writes image data with a collision-safe timestamped name, e.g.
    /// `image-20260730-142530-a1b2c3.png`, creating the folder if needed.
    static func writeImage(
        _ data: Data, fileExtension: String, assetsDirectory: URL, now: Date = Date()
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: assetsDirectory, withIntermediateDirectories: true
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)

        var url: URL
        repeat {
            let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
            url = assetsDirectory.appendingPathComponent("image-\(stamp)-\(suffix).\(fileExtension)")
        } while FileManager.default.fileExists(atPath: url.path)

        try SaveCoordinator.writeAtomically(data, to: url)
        return url
    }

    /// Relative path from the note's directory to the asset, using "../" as
    /// needed — pure string math on canonical paths.
    static func relativePath(from noteDirectory: URL, to asset: URL) -> String {
        let fromParts = AppSupportPaths.canonicalPath(of: noteDirectory)
            .split(separator: "/").map(String.init)
        let toParts = AppSupportPaths.canonicalPath(of: asset)
            .split(separator: "/").map(String.init)

        var common = 0
        while common < fromParts.count && common < toParts.count
            && fromParts[common] == toParts[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: fromParts.count - common)
        let downs = toParts[common...]
        return (ups + downs).joined(separator: "/")
    }
}
