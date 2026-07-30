import Foundation
import CryptoKit

/// Locations of app-owned metadata. Nothing here ever lives inside a user's
/// notes folder; files remain the canonical data.
enum AppSupportPaths {
    static var root: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("Ashtyn MD", isDirectory: true)
    }

    static var librariesRoot: URL {
        root.appendingPathComponent("Libraries", isDirectory: true)
    }

    static var editorProfilesFile: URL {
        root.appendingPathComponent("editor-profiles-v1.json", isDirectory: false)
    }

    /// Per-library metadata directory, keyed by the SHA-256 of the canonical
    /// (symlink-resolved) root path so the same folder always maps to the same
    /// store regardless of how it was picked.
    static func libraryDirectory(forRoot rootURL: URL) -> URL {
        let canonical = canonicalPath(of: rootURL)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return librariesRoot.appendingPathComponent(key, isDirectory: true)
    }

    static func recoveryDirectory(forLibraryRoot rootURL: URL) -> URL {
        libraryDirectory(forRoot: rootURL).appendingPathComponent("Recovery", isDirectory: true)
    }

    /// Recovery area for documents opened outside any library.
    static var standaloneRecoveryDirectory: URL {
        root.appendingPathComponent("Standalone", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }

    static func canonicalPath(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    @discardableResult
    static func ensureExists(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
