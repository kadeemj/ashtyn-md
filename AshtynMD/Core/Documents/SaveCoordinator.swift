import Foundation
import CryptoKit

/// Writes documents atomically and answers content-identity questions.
/// All functions are synchronous and thread-safe; callers run them off the
/// main actor for anything larger than trivial files.
enum SaveCoordinator {
    /// Atomically replaces (or creates) the file at `url` with `data`.
    ///
    /// The temporary file is created in the destination directory so the final
    /// rename never crosses a volume boundary and a crash mid-write can never
    /// leave a truncated document behind.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let fileManager = FileManager.default

        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).ashtyn-save-\(UUID().uuidString.prefix(8))"
        )
        try data.write(to: temporaryURL, options: [])
        defer { try? fileManager.removeItem(at: temporaryURL) }

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: temporaryURL,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }

    static func writeAtomically(_ file: LoadedTextFile, to url: URL) throws {
        try writeAtomically(try file.encodedData(), to: url)
    }

    /// Stable content hash used to detect unchanged saves and external edits.
    static func contentHash(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Current modification date and resource identifier of a file, or nil if
    /// it no longer exists. Reads through FileManager rather than
    /// URL.resourceValues, whose per-NSURL caching can return stale state.
    static func diskState(of url: URL) -> (modificationDate: Date, resourceID: String)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date else { return nil }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let device = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? ""
        return (date, "\(device):\(inode)")
    }
}
