import Foundation
import CryptoKit

/// Crash-recovery snapshots for dirty documents. One snapshot per document,
/// stored outside the notes folder, removed only after a verified save.
struct RecoverySnapshot: Codable, Sendable {
    var originalPath: String
    var savedAt: Date
    var text: String
    var encoding: TextFileEncoding
    var lineEnding: LineEnding
}

struct RecoveryStore: Sendable {
    let directory: URL

    /// Store for a document inside a library root.
    static func forLibrary(root: URL) -> RecoveryStore {
        RecoveryStore(directory: AppSupportPaths.recoveryDirectory(forLibraryRoot: root))
    }

    /// Store for standalone documents opened outside any library.
    static var standalone: RecoveryStore {
        RecoveryStore(directory: AppSupportPaths.standaloneRecoveryDirectory)
    }

    private func snapshotURL(for documentURL: URL) -> URL {
        let canonical = AppSupportPaths.canonicalPath(of: documentURL)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    func writeSnapshot(_ snapshot: RecoverySnapshot, for documentURL: URL) throws {
        try AppSupportPaths.ensureExists(directory)
        let data = try JSONEncoder().encode(snapshot)
        try SaveCoordinator.writeAtomically(data, to: snapshotURL(for: documentURL))
    }

    func snapshot(for documentURL: URL) -> RecoverySnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(for: documentURL)) else { return nil }
        return try? JSONDecoder().decode(RecoverySnapshot.self, from: data)
    }

    func removeSnapshot(for documentURL: URL) {
        try? FileManager.default.removeItem(at: snapshotURL(for: documentURL))
    }
}
