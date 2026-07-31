import AppKit
import Observation

/// Composition root for a library window.
///
/// Was a 566-line catch-all; Phase 7 split it along ownership lines so each
/// piece is constructible in a test and `@Observable` can track reads per
/// sub-model instead of invalidating every view that touched anything.
@MainActor
@Observable
final class AppModel {
    let session = LibrarySession()
    let tabs = TabsModel()
    let noteList = NoteListModel()
    let tags = TagsModel()
    let search = SearchModel()
    private(set) var actions: NoteActionsModel!

    private(set) var openError: String?

    /// Per-library opt-in: render raw HTML in Markdown previews.
    var allowRawHTML = false {
        didSet {
            guard !isRestoringState, let store = session.store else { return }
            let value = allowRawHTML ? "1" : "0"
            Task { try? await store.setAppState(value, forKey: "allowRawHTML.v1") }
        }
    }

    private var persistTask: Task<Void, Never>?
    private var isRestoringState = false

    // MARK: - Convenience forwarding
    //
    // Kept deliberately thin: menu commands and small views read these, while
    // the library views talk to the sub-models directly.

    var libraryRoot: LibraryBookmarkStore.ResolvedRoot? { session.root }
    var activeSession: DocumentSession? { tabs.activeSession }
    var sidebarSelection: SidebarItem? {
        get { noteList.selection }
        set { noteList.selection = newValue }
    }

    init() {
        actions = NoteActionsModel(
            dependencies: NoteActionsModel.Dependencies(
                session: { [unowned self] in self.session },
                didChangeFiles: { [weak self] in self?.refreshLists() },
                didChangeFolders: { [weak self] in self?.session.refreshFolderTree() },
                openFile: { [weak self] url in self?.openFile(at: url) },
                closeTab: { [weak self] url in
                    guard let self, let existing = self.tabs.session(forURL: url) else { return }
                    self.tabs.close(existing.id)
                },
                noteFileMoved: { [weak self] old, new in
                    self?.tabs.noteFileMoved(from: old, to: new)
                },
                reportError: { [weak self] message in self?.openError = message }
            )
        )

        noteList.onSelectionChange = { [weak self] in
            guard let self else { return }
            self.noteList.refresh(using: self.session)
            self.persistUIStateSoon()
        }
        search.onQueryChange = { [weak self] in
            guard let self else { return }
            self.search.refresh(using: self.session)
        }
        tabs.onTabsChange = { [weak self] in self?.persistUIStateSoon() }
        tabs.onError = { [weak self] message in self?.openError = message }

        #if DEBUG
        let configuration = UITestLaunchConfiguration.current
        if configuration.isEnabled {
            do {
                let url = try UITestLaunchConfiguration.prepareFixtureLibrary()
                if !configuration.showsOnboarding {
                    attachLibrary(.unscoped(url))
                }
            } catch {
                openError = "Couldn’t prepare UI fixtures: \(error.localizedDescription)"
            }
            return
        }
        #endif
        if let root = LibraryBookmarkStore.resolveKnownRoots().first {
            attachLibrary(root)
        }
    }

    // MARK: - Library selection

    func chooseLibraryFolder() {
        #if DEBUG
        if UITestLaunchConfiguration.current.isEnabled {
            do {
                attachLibrary(
                    .unscoped(try UITestLaunchConfiguration.prepareFixtureLibrary())
                )
            } catch {
                openError = "Couldn’t prepare UI fixtures: \(error.localizedDescription)"
            }
            return
        }
        #endif
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Library"
        panel.message = "Choose the folder where Ashtyn MD keeps your notes. Files stay ordinary files in this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LibraryBookmarkStore.saveRoot(url)
        } catch {
            openError = "Couldn’t remember access to that folder: \(error.localizedDescription)"
            return
        }
        if let resolved = LibraryBookmarkStore.resolveKnownRoots()
            .first(where: { AppSupportPaths.canonicalPath(of: $0.url) == AppSupportPaths.canonicalPath(of: url) }) {
            attachLibrary(resolved)
        }
    }

    private func attachLibrary(_ root: LibraryBookmarkStore.ResolvedRoot) {
        detachLibrary()
        Task {
            do {
                let store = try session.attach(root)
                tabs.storeForPersistence = store
                // The capture folder exists from the first launch, so ⌘N always
                // has somewhere to go.
                try? InboxFolder.ensureExists(in: root.url)
                AppModelChangeRelay.shared.register(self)
                await restoreUIState()
                try await session.startIndexing()
                refreshLists()
            } catch {
                openError = "Couldn’t open the library index: \(error.localizedDescription)"
            }
        }
    }

    private func detachLibrary() {
        search.cancel()
        persistTask?.cancel()
        persistTask = nil
        tabs.closeAll()
        tabs.storeForPersistence = nil
        let previous = session.detach()
        Task {
            await previous.indexer?.stop()
            try? await previous.store?.close()
            previous.root?.stopAccessing()
        }
    }

    /// Called by the change relay whenever the indexer commits a batch.
    func libraryIndexDidChange() {
        refreshLists()
        session.refreshFolderTree()
        if noteList.selection == .search { search.refresh(using: session) }
    }

    func noteIndexingProgress(_ progress: IndexingProgress) {
        session.noteIndexingProgress(progress)
    }

    private func refreshLists() {
        noteList.refresh(using: session)
        tags.refresh(using: session)
    }

    // MARK: - Paths and files

    func absoluteURL(of record: FileRecord) -> URL? { session.absoluteURL(of: record) }
    func relativePath(of url: URL) -> String? { session.relativePath(of: url) }
    func contains(_ url: URL) -> Bool { session.contains(url) }

    func openFile(at url: URL) {
        tabs.open(url: url, using: session)
        openError = nil
    }

    // MARK: - Tagging by drag

    /// Adds `#tag` to a note's text.
    ///
    /// Tags are content, so there is nowhere else for a dropped tag to go. An
    /// open note is edited through `performSourceEdit` to join the native undo
    /// stack — the same route the preview's checkbox toggles take.
    func addTag(_ key: String, toFileAt url: URL) {
        guard contains(url) else { return }
        let insertion = "#\(key)"

        if let open = tabs.session(forURL: url) {
            guard let edit = TagInsertion.plan(for: insertion, in: open.text) else { return }
            open.performSourceEdit(range: edit.range, replacement: edit.replacement)
            return
        }
        do {
            let file = try LoadedTextFile.load(from: url)
            guard let edit = TagInsertion.plan(for: insertion, in: file.text) else { return }
            let updated = (file.text as NSString)
                .replacingCharacters(in: edit.range, with: edit.replacement)
            var rewritten = file
            rewritten.text = updated
            try SaveCoordinator.writeAtomically(rewritten, to: url)
        } catch {
            openError = "Couldn’t add #\(key): \(error.localizedDescription)"
        }
    }

    // MARK: - UI state persistence

    private struct PersistedUIState: Codable {
        var openTabPaths: [String]
        var activeTabPath: String?
        var selectedFolderPath: String?
        var selectionKind: String
        var selectedTagKey: String?
        var sortOrderRaw: String?
    }

    private func persistUIStateSoon() {
        guard !isRestoringState, let store = session.store else { return }
        persistTask?.cancel()
        let state = currentUIState()
        persistTask = Task {
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(state),
               let json = String(data: data, encoding: .utf8) {
                try? await store.setAppState(json, forKey: "windowState.v1")
            }
        }
    }

    private func currentUIState() -> PersistedUIState {
        var kind = "notes"
        var folderPath: String?
        var tagKey: String?
        switch noteList.selection {
        case .inbox: kind = "inbox"
        case .untagged: kind = "untagged"
        case .todo: kind = "todo"
        case .pinned: kind = "pinned"
        case .favorites: kind = "favorites"
        case .recents: kind = "recents"
        case .archive: kind = "archive"
        case .trash: kind = "trash"
        case .search: kind = "search"
        case .tag(let key):
            kind = "tag"
            tagKey = key
        case .folder(let url):
            kind = "folder"
            folderPath = session.relativePath(of: url)
        default: kind = "notes"
        }
        return PersistedUIState(
            openTabPaths: tabs.tabs.compactMap { session.relativePath(of: $0.fileURL) },
            activeTabPath: tabs.activeSession.flatMap { session.relativePath(of: $0.fileURL) },
            selectedFolderPath: folderPath,
            selectionKind: kind,
            selectedTagKey: tagKey,
            sortOrderRaw: noteList.sortOrder.rawValue
        )
    }

    private func restoreUIState() async {
        guard let store = session.store, let root = session.root?.url else { return }
        guard let json = try? await store.appState(forKey: "windowState.v1"),
              let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(PersistedUIState.self, from: data)
        else {
            // A brand-new library still lands on the Inbox.
            noteList.selection = .inbox
            return
        }

        isRestoringState = true
        defer { isRestoringState = false }

        if let rawHTML = try? await store.appState(forKey: "allowRawHTML.v1") {
            allowRawHTML = rawHTML == "1"
        }
        if let raw = state.sortOrderRaw,
           let order = LibraryStore.SortOrder(rawValue: raw) {
            noteList.sortOrder = order
        }

        // Tabs and cursor positions come back, but the sidebar always lands on
        // the Inbox: launching should mean "ready to capture", with whatever was
        // open still one click away in the tab bar. selectionKind is still
        // persisted, for anything that wants to know where the user was.
        noteList.selection = .inbox

        for path in state.openTabPaths {
            let url = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            openFile(at: url)
        }
        if let activePath = state.activeTabPath {
            let url = root.appendingPathComponent(activePath)
            // openFile is async; activate once the tab exists.
            Task {
                for _ in 0..<50 {
                    if let tab = tabs.tabs.first(where: { $0.fileURL == url }) {
                        tabs.activeTabID = tab.id
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }
}

/// The indexer's callbacks fire from arbitrary tasks; this relay hops to the
/// main actor and fans out to the models that care.
@MainActor
final class AppModelChangeRelay {
    static let shared = AppModelChangeRelay()
    private var models: [WeakBox] = []

    private struct WeakBox { weak var model: AppModel? }

    func register(_ model: AppModel) {
        models.removeAll { $0.model == nil || $0.model === model }
        models.append(WeakBox(model: model))
    }

    func libraryDidChange() {
        models.removeAll { $0.model == nil }
        for box in models {
            box.model?.libraryIndexDidChange()
        }
    }

    func indexingProgressDidChange(_ progress: IndexingProgress) {
        models.removeAll { $0.model == nil }
        for box in models {
            box.model?.noteIndexingProgress(progress)
        }
    }
}
