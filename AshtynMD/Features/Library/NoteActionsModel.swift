import Foundation
import Observation

/// Everything a user does *to* a note: create, capture, file, favorite, pin,
/// rename, duplicate, trash.
///
/// Dependencies arrive as closures rather than a back-reference to AppModel, so
/// this is constructible in a test with stubs.
@MainActor
@Observable
final class NoteActionsModel {
    struct Dependencies {
        var session: () -> LibrarySession
        var didChangeFiles: () -> Void
        var didChangeFolders: () -> Void
        var reindex: () -> Void
        var openFile: (URL) -> Void
        var openDocument: (URL) -> DocumentSession?
        var closeTab: (URL) -> Void
        var noteFileMoved: (URL, URL) -> Void
        var requestTitleRename: (URL) -> Void
        var reportError: (String) -> Void
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    private var session: LibrarySession { dependencies.session() }

    // MARK: - Creating

    /// ⌘N: capture to the Inbox regardless of what is selected.
    func newNoteInInbox(language: LanguageID = .markdown, seedTag: String? = nil) {
        guard let root = session.root?.url else { return }
        do {
            let folder = try InboxFolder.ensureExists(in: root)
            try create(language: language, in: folder, seedTag: seedTag)
        } catch {
            dependencies.reportError("Couldn’t create the note: \(error.localizedDescription)")
        }
    }

    /// ⌥⌘N: create where the sidebar points.
    ///
    /// A tag is not a location, so a tag selection still writes to the Inbox and
    /// seeds the tag into the body instead.
    func newNoteInSelectedLocation(
        language: LanguageID = .markdown,
        selection: SidebarItem?
    ) {
        switch selection {
        case .folder(let url):
            do {
                try create(language: language, in: url, seedTag: nil)
            } catch {
                dependencies.reportError("Couldn’t create the note: \(error.localizedDescription)")
            }
        case .tag(let key):
            newNoteInInbox(language: language, seedTag: key)
        default:
            newNoteInInbox(language: language)
        }
    }

    private func create(language: LanguageID, in folder: URL, seedTag: String?) throws {
        let definition = LanguageDefinition.definition(for: language)
        let url = LibraryBrowser.availableURL(
            in: folder, baseName: "Untitled", ext: definition.preferredExtension
        )
        // Body starts empty apart from an optional tag line, with the caret on
        // line 1, so the first thing typed becomes both title and filename.
        let body = seedTag.map { "\n\n#\($0)\n" } ?? ""
        try SaveCoordinator.writeAtomically(Data(body.utf8), to: url)
        dependencies.openFile(url)
        dependencies.didChangeFiles()
        // The file was created outside the indexer's event stream. Reconcile
        // immediately so the Inbox/list reflects the new note as soon as the
        // editor opens, including on filesystems where FSEvents coalesces it.
        dependencies.reindex()
    }

    func newFolder(named name: String, selection: SidebarItem?) {
        let parent: URL? = {
            if case .folder(let url) = selection { return url }
            return session.root?.url
        }()
        guard let parent else { return }
        do {
            _ = try FileOperations.createFolder(named: name, in: parent)
            dependencies.didChangeFolders()
        } catch {
            dependencies.reportError("Couldn’t create the folder: \(error.localizedDescription)")
        }
    }

    // MARK: - Filing

    /// ⌃⌘M: move notes out of the Inbox (or anywhere) into a folder.
    func move(_ records: [FileRecord], into folder: URL) {
        guard session.contains(folder) || folder == session.root?.url else { return }
        for record in records {
            guard let url = session.absoluteURL(of: record) else { continue }
            do {
                let newURL = try FileOperations.move(url, into: folder)
                dependencies.noteFileMoved(url, newURL)
            } catch {
                dependencies.reportError("Couldn’t move “\(record.name)”: \(error.localizedDescription)")
            }
        }
        dependencies.didChangeFiles()
    }

    /// Drag-and-drop onto a sidebar folder.
    func moveFile(at sourceURL: URL, into folder: URL) {
        guard session.contains(sourceURL),
              session.contains(folder) || folder == session.root?.url else { return }
        do {
            let newURL = try FileOperations.move(sourceURL, into: folder)
            dependencies.noteFileMoved(sourceURL, newURL)
            dependencies.didChangeFiles()
        } catch {
            dependencies.reportError("Couldn’t move the file: \(error.localizedDescription)")
        }
    }

    // MARK: - Flags

    func toggleFavorite(_ record: FileRecord) {
        guard let store = session.store else { return }
        Task {
            try? await store.setFavorite(!record.isFavorite, relativePath: record.relativePath)
            dependencies.didChangeFiles()
        }
    }

    func togglePinned(_ record: FileRecord) {
        guard let store = session.store else { return }
        Task {
            try? await store.setPinned(!record.isPinned, relativePath: record.relativePath)
            dependencies.didChangeFiles()
        }
    }

    // MARK: - Renaming and copying

    func rename(_ record: FileRecord, to newName: String) {
        guard let url = session.absoluteURL(of: record), !newName.isEmpty,
              newName != record.name else { return }
        do {
            let newURL = try FileOperations.rename(url, to: newName)
            dependencies.noteFileMoved(url, newURL)
            // Typing a filename is the strongest possible signal that the user
            // wants that name, so stop deriving it from the title.
            if let store = session.store {
                let path = session.relativePath(of: newURL) ?? record.relativePath
                Task { try? await store.setTitleIsManaged(false, relativePath: path) }
            }
            dependencies.didChangeFiles()
        } catch {
            dependencies.reportError("Couldn’t rename: \(error.localizedDescription)")
        }
    }

    /// Re-enables title-managed filenames after a user explicitly chose a
    /// filename in the Rename dialog.
    func useTitleAsFilename(_ record: FileRecord) {
        guard let store = session.store else { return }
        let path = record.relativePath
        Task {
            do {
                try await store.setTitleIsManaged(true, relativePath: path)
                if let url = session.absoluteURL(of: record) {
                    dependencies.requestTitleRename(url)
                }
                dependencies.didChangeFiles()
            } catch {
                dependencies.reportError(
                    "Couldn’t re-enable title filenames: \(error.localizedDescription)"
                )
            }
        }
    }

    func duplicate(_ record: FileRecord) {
        guard let url = session.absoluteURL(of: record) else { return }
        do {
            _ = try FileOperations.duplicate(url)
            dependencies.didChangeFiles()
        } catch {
            dependencies.reportError("Couldn’t duplicate: \(error.localizedDescription)")
        }
    }

    // MARK: - Lifecycle

    func archive(_ records: [FileRecord]) {
        guard let root = session.root?.url else { return }
        for record in records {
            guard let url = session.absoluteURL(of: record) else { continue }
            do {
                let archived = try NoteLifecycle.archive(url, in: root)
                dependencies.noteFileMoved(url, archived)
            } catch {
                dependencies.reportError(
                    "Couldn’t archive “\(record.name)”: \(error.localizedDescription)"
                )
            }
        }
        dependencies.didChangeFiles()
        dependencies.reindex()
    }

    func unarchive(_ records: [FileRecord]) {
        guard let root = session.root?.url else { return }
        for record in records {
            guard let url = session.absoluteURL(of: record) else { continue }
            do {
                let restored = try NoteLifecycle.unarchive(url, in: root)
                dependencies.noteFileMoved(url, restored)
            } catch {
                dependencies.reportError(
                    "Couldn’t unarchive “\(record.name)”: \(error.localizedDescription)"
                )
            }
        }
        dependencies.didChangeFiles()
        dependencies.reindex()
    }

    func restoreFromTrash(_ records: [FileRecord]) {
        guard let root = session.root?.url else { return }
        for record in records {
            guard let url = session.absoluteURL(of: record) else { continue }
            do {
                let restored = try NoteLifecycle.restore(url, in: root)
                dependencies.noteFileMoved(url, restored)
            } catch {
                dependencies.reportError(
                    "Couldn’t restore “\(record.name)”: \(error.localizedDescription)"
                )
            }
        }
        dependencies.didChangeFiles()
        dependencies.reindex()
    }

    /// Moves notes to Ashtyn MD's recoverable in-library Trash.
    func moveToTrash(_ records: [FileRecord]) {
        guard let root = session.root?.url else { return }
        Task { [weak self] in
            guard let self else { return }
            for record in records {
                guard let url = session.absoluteURL(of: record),
                      await saveAndCloseIfOpen(url, name: record.name) else { continue }
                do {
                    _ = try NoteLifecycle.trash(
                        url,
                        in: root,
                        title: record.title.isEmpty ? record.name : record.title
                    )
                } catch {
                    dependencies.reportError(
                        "Couldn’t move “\(record.name)”: \(error.localizedDescription)"
                    )
                }
            }
            dependencies.didChangeFiles()
            dependencies.reindex()
        }
    }

    /// Sends a note from Ashtyn MD's Trash to the macOS system Trash, making
    /// this the final recovery layer.
    func deletePermanently(_ records: [FileRecord]) {
        guard let store = session.store else { return }
        Task { [weak self] in
            guard let self else { return }
            for record in records {
                guard let url = session.absoluteURL(of: record),
                      await saveAndCloseIfOpen(url, name: record.name) else { continue }
                do {
                    try FileOperations.trash(url)
                    try await store.removeFile(relativePath: record.relativePath)
                } catch {
                    dependencies.reportError(
                        "Couldn’t delete “\(record.name)”: \(error.localizedDescription)"
                    )
                }
            }
            dependencies.didChangeFiles()
            dependencies.reindex()
        }
    }

    private func saveAndCloseIfOpen(_ url: URL, name: String) async -> Bool {
        guard let document = dependencies.openDocument(url) else { return true }
        await document.save(reason: .explicit)
        guard document.conflict == .none,
              !document.isDirty,
              document.lastSaveError == nil else {
            dependencies.reportError(
                "Couldn’t remove “\(name)” because its latest edits could not be saved."
            )
            return false
        }
        dependencies.closeTab(url)
        return true
    }
}
