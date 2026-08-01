import Foundation

/// The on-disk recovery layer for notes inside a library.
///
/// The SQLite index mirrors this state for fast lists, but these directories
/// are the source of truth. A deleted index can therefore be rebuilt without
/// resurrecting archived or trashed notes.
enum NoteLifecycle {
    static let trashDirectoryName = ".trash"
    static let archiveDirectoryName = ".archive"
    static let trashMetadataName = "meta.json"

    struct TrashMetadata: Codable, Equatable, Sendable {
        let originalRelativePath: String
        let trashedAt: Date
        let title: String
    }

    struct TrashedItem: Equatable, Sendable {
        let url: URL
        let metadata: TrashMetadata
    }

    enum LifecycleError: LocalizedError, Equatable {
        case sourceOutsideLibrary
        case invalidRelativePath(String)
        case sourceAlreadyInLifecycleDirectory
        case destinationAlreadyExists(URL)
        case missingTrashMetadata(URL)
        case invalidTrashLocation(URL)

        var errorDescription: String? {
            switch self {
            case .sourceOutsideLibrary:
                return "The file is outside the selected library."
            case .invalidRelativePath(let path):
                return "The lifecycle path is invalid: \(path)."
            case .sourceAlreadyInLifecycleDirectory:
                return "The file is already in Archive or Trash."
            case .destinationAlreadyExists(let url):
                return "A file already exists at “\(url.lastPathComponent)”."
            case .missingTrashMetadata(let url):
                return "Trash metadata is missing for “\(url.lastPathComponent)”."
            case .invalidTrashLocation(let url):
                return "The file is not inside the library Trash: \(url.path)."
            }
        }
    }

    // MARK: - Public mutations

    @discardableResult
    static func archive(_ sourceURL: URL, in root: URL) throws -> URL {
        let relative = try relativePath(of: sourceURL, in: root)
        guard !isLifecyclePath(relative) else {
            throw LifecycleError.sourceAlreadyInLifecycleDirectory
        }

        let destination = try safeURL(
            for: "\(archiveDirectoryName)/\(relative)", in: root
        )
        try ensureDestinationIsFree(destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: sourceURL, to: destination)
        return destination
    }

    @discardableResult
    static func unarchive(_ archivedURL: URL, in root: URL) throws -> URL {
        let relative = try relativePath(of: archivedURL, in: root)
        guard let original = originalRelativePath(ofArchivePath: relative) else {
            throw LifecycleError.invalidRelativePath(relative)
        }

        let destination = try safeURL(for: original, in: root)
        try ensureDestinationIsFree(destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: archivedURL, to: destination)
        return destination
    }

    @discardableResult
    static func trash(
        _ sourceURL: URL,
        in root: URL,
        title: String,
        now: Date = Date()
    ) throws -> TrashedItem {
        let originalRelativePath = try relativePath(of: sourceURL, in: root)
        guard !isLifecyclePath(originalRelativePath) else {
            throw LifecycleError.sourceAlreadyInLifecycleDirectory
        }

        let metadata = TrashMetadata(
            originalRelativePath: originalRelativePath,
            trashedAt: now,
            title: title
        )
        let trashDirectory = root
            .appendingPathComponent(trashDirectoryName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: trashDirectory, withIntermediateDirectories: true
        )

        // A note named meta.json would otherwise collide with our manifest.
        let storedName = sourceURL.lastPathComponent == trashMetadataName
            ? ".note-\(sourceURL.lastPathComponent)"
            : sourceURL.lastPathComponent
        let destination = trashDirectory.appendingPathComponent(storedName)
        let metadataURL = trashDirectory.appendingPathComponent(trashMetadataName)

        do {
            try FileManager.default.moveItem(at: sourceURL, to: destination)
            try writeMetadata(metadata, to: metadataURL)
        } catch {
            // A failed manifest write must not strand the user's note in the
            // private Trash with no way to restore it.
            if FileManager.default.fileExists(atPath: destination.path),
               !FileManager.default.fileExists(atPath: sourceURL.path) {
                try? FileManager.default.moveItem(at: destination, to: sourceURL)
            }
            try? FileManager.default.removeItem(at: trashDirectory)
            throw error
        }

        return TrashedItem(url: destination, metadata: metadata)
    }

    @discardableResult
    static func restore(_ trashedURL: URL, in root: URL) throws -> URL {
        let relative = try relativePath(of: trashedURL, in: root)
        guard isTrashPath(relative) else {
            throw LifecycleError.invalidTrashLocation(trashedURL)
        }
        let metadata = try metadata(for: trashedURL)
        let destination = try safeURL(for: metadata.originalRelativePath, in: root)
        try ensureDestinationIsFree(destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: trashedURL, to: destination)

        let trashDirectory = trashedURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(
            at: trashDirectory.appendingPathComponent(trashMetadataName)
        )
        try? FileManager.default.removeItem(at: trashDirectory)
        return destination
    }

    static func metadata(for trashedURL: URL) throws -> TrashMetadata {
        let directory = trashedURL.deletingLastPathComponent()
        let metadataURL = directory.appendingPathComponent(trashMetadataName)
        guard let data = try? Data(contentsOf: metadataURL) else {
            throw LifecycleError.missingTrashMetadata(trashedURL)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TrashMetadata.self, from: data)
    }

    // MARK: - Path helpers

    static func originalRelativePath(ofArchivePath relativePath: String) -> String? {
        let prefix = archiveDirectoryName + "/"
        guard relativePath.hasPrefix(prefix) else { return nil }
        let original = String(relativePath.dropFirst(prefix.count))
        return original.isEmpty ? nil : original
    }

    static func isArchivePath(_ relativePath: String) -> Bool {
        relativePath == archiveDirectoryName ||
            relativePath.hasPrefix(archiveDirectoryName + "/")
    }

    static func isTrashPath(_ relativePath: String) -> Bool {
        relativePath == trashDirectoryName ||
            relativePath.hasPrefix(trashDirectoryName + "/")
    }

    static func isLifecyclePath(_ relativePath: String) -> Bool {
        isArchivePath(relativePath) || isTrashPath(relativePath)
    }

    private static func relativePath(of url: URL, in root: URL) throws -> String {
        let rootPath = AppSupportPaths.canonicalPath(of: root)
        let path = AppSupportPaths.canonicalPath(of: url)
        guard path.hasPrefix(rootPath + "/") else {
            throw LifecycleError.sourceOutsideLibrary
        }
        let relative = String(path.dropFirst(rootPath.count + 1))
        guard !relative.isEmpty else {
            throw LifecycleError.invalidRelativePath(relative)
        }
        return relative
    }

    private static func safeURL(for relativePath: String, in root: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(where: { $0 == ".." })
        else {
            throw LifecycleError.invalidRelativePath(relativePath)
        }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = AppSupportPaths.canonicalPath(of: root)
        guard candidate.path.hasPrefix(rootPath + "/") else {
            throw LifecycleError.invalidRelativePath(relativePath)
        }
        return candidate
    }

    private static func ensureDestinationIsFree(_ destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LifecycleError.destinationAlreadyExists(destination)
        }
    }

    private static func writeMetadata(_ metadata: TrashMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SaveCoordinator.writeAtomically(encoder.encode(metadata), to: url)
    }
}
