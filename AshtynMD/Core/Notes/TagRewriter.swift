import Foundation

/// Pure Markdown tag rewrites plus the durable snapshot store used to undo a
/// multi-file rename or deletion.
enum TagRewriter {
    static let maximumFiles = 2_000

    enum RewriteError: LocalizedError, Equatable {
        case invalidTag(String)
        case tooManyFiles(Int)

        var errorDescription: String? {
            switch self {
            case .invalidTag(let tag): return "“\(tag)” is not a valid tag path."
            case .tooManyFiles(let count):
                return "This tag appears in \(count) notes; rewrites are limited to \(maximumFiles) files."
            }
        }
    }

    /// Returns the rewritten text, or nil when no matching tag exists.
    /// Ranges are applied from the end of the document so earlier offsets stay
    /// valid while a closing-hash tag or nested tag is replaced.
    static func rewrite(
        _ text: String,
        oldKey rawOldKey: String,
        replacement rawReplacement: String?
    ) throws -> String? {
        let oldKey = MarkdownTag.fold(rawOldKey)
        guard !oldKey.isEmpty else { throw RewriteError.invalidTag(rawOldKey) }

        let replacementPath: String?
        if let rawReplacement {
            replacementPath = try validDisplayPath(rawReplacement)
        } else {
            replacementPath = nil
        }

        let tags = MarkdownTagScanner.tags(in: text as NSString)
        let oldComponents = oldKey.split(separator: "/").map(String.init)
        let edits: [(NSRange, String)] = tags.compactMap { tag in
            guard tag.key == oldKey || tag.key.hasPrefix(oldKey + "/") else { return nil }

            let replacement: String
            if let replacementPath {
                let suffix = Array(tag.components.dropFirst(oldComponents.count))
                let path = ([replacementPath] + suffix).joined(separator: "/")
                replacement = tag.isClosingHashForm ? "#\(path)#" : "#\(path)"
            } else {
                replacement = ""
            }
            return (tag.range, replacement)
        }

        guard !edits.isEmpty else { return nil }
        let mutable = NSMutableString(string: text)
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            mutable.replaceCharacters(in: range, with: replacement)
        }
        return String(mutable)
    }

    private static func validDisplayPath(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        if value.hasSuffix("#") { value.removeLast() }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = value.split(separator: "/").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && !$0.contains("#") }) else {
            throw RewriteError.invalidTag(raw)
        }

        let display = components.joined(separator: "/")
        let key = MarkdownTag.fold(display)
        guard !key.isEmpty, key.contains(where: { !$0.isNumber && $0 != "/" }) else {
            throw RewriteError.invalidTag(raw)
        }
        // Let the shared scanner remain the grammar authority. A synthetic
        // tag must round-trip through it before a disk rewrite is attempted.
        let synthetic = display.contains(where: { $0.isWhitespace })
            ? "#\(display)#"
            : "#\(display)"
        let parsed = MarkdownTagScanner.tags(in: synthetic as NSString)
        guard parsed.count == 1, parsed[0].key == key else {
            throw RewriteError.invalidTag(raw)
        }
        return display
    }
}

struct TagRewriteSnapshotManifest: Codable, Equatable, Sendable {
    let oldKey: String
    let replacement: String?
    let createdAt: Date
    let relativePaths: [String]
}

/// Stores original bytes, not normalized text, so undo preserves encoding,
/// BOM, line endings, and any non-UTF-8 details of every note.
enum TagRewriteUndoStore {
    static let directoryName = "TagRewrites"
    private static let filesDirectoryName = "files"
    private static let manifestName = "manifest.json"

    static func create(
        root: URL,
        oldKey: String,
        replacement: String?,
        originals: [(relativePath: String, data: Data)],
        now: Date = Date()
    ) throws -> URL {
        guard originals.count <= TagRewriter.maximumFiles else {
            throw TagRewriter.RewriteError.tooManyFiles(originals.count)
        }

        let snapshot = AppSupportPaths.libraryDirectory(forRoot: root)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filesDirectory = snapshot.appendingPathComponent(filesDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)

        for original in originals {
            let destination = filesDirectory.appendingPathComponent(original.relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try original.data.write(to: destination, options: [.atomic])
        }

        let manifest = TagRewriteSnapshotManifest(
            oldKey: oldKey,
            replacement: replacement,
            createdAt: now,
            relativePaths: originals.map { $0.relativePath }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SaveCoordinator.writeAtomically(
            encoder.encode(manifest),
            to: snapshot.appendingPathComponent(manifestName)
        )
        return snapshot
    }

    static func latest(in root: URL) -> URL? {
        let directory = AppSupportPaths.libraryDirectory(forRoot: root)
            .appendingPathComponent(directoryName, isDirectory: true)
        let snapshots = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return snapshots.compactMap { snapshot -> (url: URL, date: Date)? in
            guard snapshot.hasDirectoryPath,
                  let data = try? Data(contentsOf: snapshot.appendingPathComponent(manifestName)),
                  let manifest = try? decoder.decode(TagRewriteSnapshotManifest.self, from: data)
            else { return nil }
            return (snapshot, manifest.createdAt)
        }
        .max {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }?.url
    }

    @discardableResult
    static func restoreLatest(in root: URL) throws -> [String] {
        guard let snapshot = latest(in: root) else { return [] }
        let manifestURL = snapshot.appendingPathComponent(manifestName)
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(TagRewriteSnapshotManifest.self, from: data)
        let filesDirectory = snapshot.appendingPathComponent(filesDirectoryName)

        for path in manifest.relativePaths {
            let source = filesDirectory.appendingPathComponent(path)
            let destination = root.appendingPathComponent(path)
            guard let original = try? Data(contentsOf: source) else { continue }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try SaveCoordinator.writeAtomically(original, to: destination)
        }

        try? FileManager.default.removeItem(at: snapshot)
        return manifest.relativePaths
    }
}
