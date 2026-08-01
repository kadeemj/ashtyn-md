import Foundation

/// Debounced first-line → filename synchronization for open library notes.
///
/// Standalone documents never install the `TabsModel` callback that reaches
/// this coordinator, so Finder-opened files remain untouched. Saving always
/// finishes before the rename is attempted because SaveCoordinator resolves
/// its atomic temporary destination at call time.
@MainActor
final class TitleRenameCoordinator {
    struct Dependencies {
        var librarySession: () -> LibrarySession
        var isEnabled: () -> Bool
        var isRestoringState: () -> Bool
        var noteFileMoved: (URL, URL) -> Void
        var didChangeFiles: () -> Void
        var reportError: (String) -> Void
    }

    private let dependencies: Dependencies
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UInt64] = [:]
    private var failedSessions = Set<UUID>()

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func schedule(for document: DocumentSession) {
        let id = document.id
        generations[id, default: 0] &+= 1
        let generation = generations[id]!
        tasks[id]?.cancel()

        guard canRename(document), !failedSessions.contains(id) else { return }
        tasks[id] = Task { [weak self, weak document] in
            do {
                try await Task.sleep(for: .milliseconds(1_200))
            } catch {
                return
            }
            guard let self, let document,
                  self.generations[id] == generation,
                  !Task.isCancelled else { return }
            await self.reconcile(document)
        }
    }

    func reconcileOpenDocuments(_ documents: [DocumentSession]) {
        for document in documents {
            schedule(for: document)
        }
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        generations.removeAll()
    }

    func resetFailure(for document: DocumentSession) {
        failedSessions.remove(document.id)
        schedule(for: document)
    }

    private func canRename(_ document: DocumentSession) -> Bool {
        guard dependencies.isEnabled(), !dependencies.isRestoringState(),
              document.languageID == .markdown,
              document.conflict == .none else { return false }
        let library = dependencies.librarySession()
        guard library.contains(document.fileURL),
              let relative = library.relativePath(of: document.fileURL) else { return false }
        return !NoteLifecycle.isLifecyclePath(relative)
    }

    private func reconcile(_ document: DocumentSession) async {
        defer { tasks[document.id] = nil }
        guard canRename(document), !failedSessions.contains(document.id) else { return }

        let hashBeforeSave = SaveCoordinator.contentHash(of: document.text)
        document.checkForExternalChanges()
        guard document.conflict == .none else { return }
        await document.save(reason: .explicit)

        // A save may have raced a newer edit. The newer callback owns the next
        // debounce; this task must not rename the filename for stale content.
        guard document.conflict == .none,
              !document.isDirty,
              document.lastSaveError == nil,
              SaveCoordinator.contentHash(of: document.text) == hashBeforeSave else {
            return
        }

        let parsed = MarkdownMetadata.parse(document.text)
        guard let desiredBaseName = TitleFilename.sanitizedBaseName(parsed.title),
              !parsed.title.isEmpty else { return }

        let library = dependencies.librarySession()
        guard let store = library.store,
              let indexer = library.indexer,
              let oldRelativePath = library.relativePath(of: document.fileURL),
              let record = try? await store.record(forRelativePath: oldRelativePath),
              record.titleIsManaged else { return }

        guard !TitleFilename.matches(document.fileURL.lastPathComponent, title: parsed.title)
        else { return }

        let folder = document.fileURL.deletingLastPathComponent()
        let extensionName = document.fileURL.pathExtension
        let destination = LibraryBrowser.availableURL(
            in: folder, baseName: desiredBaseName, ext: extensionName
        )
        guard destination != document.fileURL else { return }

        let oldURL = document.fileURL
        do {
            let newURL = try FileOperations.rename(
                oldURL, to: destination.lastPathComponent
            )
            guard let newRelativePath = library.relativePath(of: newURL) else {
                throw RenameError.destinationOutsideLibrary
            }

            do {
                try await indexer.applyRename(
                    from: oldRelativePath, to: newRelativePath
                )
            } catch {
                fail(
                    document,
                    message: "The note was renamed, but its index could not be updated: \(error.localizedDescription)"
                )
            }

            dependencies.noteFileMoved(oldURL, newURL)
            dependencies.didChangeFiles()
        } catch {
            fail(document, message: "Couldn’t rename the note: \(error.localizedDescription)")
        }
    }

    private func fail(_ document: DocumentSession, message: String) {
        guard failedSessions.insert(document.id).inserted else { return }
        tasks[document.id]?.cancel()
        dependencies.reportError(message)
    }

    private enum RenameError: LocalizedError {
        case destinationOutsideLibrary

        var errorDescription: String? {
            "The new filename would leave the selected library."
        }
    }
}
