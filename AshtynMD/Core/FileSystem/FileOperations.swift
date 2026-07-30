import Foundation

/// Filesystem mutations the library UI performs. All throwing, all plain
/// FileManager operations — FSEvents picks the results up for the index.
enum FileOperations {
    @discardableResult
    static func createFolder(named name: String, in parent: URL) throws -> URL {
        let target = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    /// Renames within the same directory; returns the new URL.
    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Moves a file or folder into `folder`, keeping its name.
    @discardableResult
    static func move(_ url: URL, into folder: URL) throws -> URL {
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Duplicates next to the original with a collision-safe name
    /// ("note copy.md", "note copy 2.md", …).
    @discardableResult
    static func duplicate(_ url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let fileManager = FileManager.default

        var candidateName = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
        var counter = 2
        while fileManager.fileExists(atPath: folder.appendingPathComponent(candidateName).path) {
            candidateName = ext.isEmpty ? "\(base) copy \(counter)" : "\(base) copy \(counter).\(ext)"
            counter += 1
        }
        let destination = folder.appendingPathComponent(candidateName)
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    /// Deletes via the macOS Trash so the file remains recoverable.
    static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
