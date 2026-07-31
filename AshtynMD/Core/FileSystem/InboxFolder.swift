import Foundation

/// The capture folder: `<library>/Inbox`.
///
/// Deliberately an ordinary directory rather than a smart list. "File it into a
/// folder" has to mean a real `moveItem`, so the state is visible in Finder,
/// survives an index rebuild, and syncs correctly — the same reasoning that
/// keeps trash and archive on disk. Consequently there is nothing about the
/// Inbox in the schema: membership is just a path prefix.
enum InboxFolder {
    static let name = "Inbox"

    static func url(in root: URL) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    /// Creates the folder if it is missing and returns it.
    ///
    /// Called on attach and again before each capture, so deleting it in Finder
    /// is a recoverable mistake rather than a broken app. If the user already
    /// has a folder named Inbox, it simply *is* the Inbox — nothing is created
    /// and nothing is moved.
    @discardableResult
    static func ensureExists(in root: URL) throws -> URL {
        let directory = url(in: root)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            // A *file* named Inbox would make captures fail; fall back to the
            // root rather than clobbering something the user made.
            guard isDirectory.boolValue else { return root }
            return directory
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory
    }

    /// True when `relativePath` names something inside the Inbox.
    static func contains(relativePath: String) -> Bool {
        relativePath.hasPrefix(name + "/")
    }
}
