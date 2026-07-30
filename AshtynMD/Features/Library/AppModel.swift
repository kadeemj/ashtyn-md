import AppKit
import Observation

enum SidebarItem: Hashable {
    case allFiles
    case favorites
    case recents
    case search
    case folder(URL)
}

/// State for a library window: the active root, sidebar selection, indexed
/// file lists, open tabs, and search.
@MainActor
@Observable
final class AppModel {
    private(set) var libraryRoot: LibraryBookmarkStore.ResolvedRoot?
    private(set) var folderTree: FolderNode?
    private(set) var store: LibraryStore?
    private(set) var indexer: LibraryIndexer?

    var sidebarSelection: SidebarItem? = .allFiles {
        didSet {
            refreshFileList()
            persistUIStateSoon()
        }
    }
    var sortOrder: LibraryStore.SortOrder = .modifiedDescending {
        didSet { refreshFileList() }
    }
    private(set) var files: [FileRecord] = []

    var searchQuery: String = "" {
        didSet { scheduleSearch() }
    }
    private(set) var searchResults: [SearchResult] = []

    private(set) var tabs: [DocumentSession] = []
    var activeTabID: UUID? {
        didSet { persistUIStateSoon() }
    }
    var activeSession: DocumentSession? {
        tabs.first { $0.id == activeTabID }
    }

    private(set) var openError: String?
    /// Per-library opt-in: render raw HTML in Markdown previews.
    var allowRawHTML = false {
        didSet {
            guard !isRestoringState, let store else { return }
            let value = allowRawHTML ? "1" : "0"
            Task { try? await store.setAppState(value, forKey: "allowRawHTML.v1") }
        }
    }
    /// Session id → indexed file id, for view-state persistence.
    private var sessionFileIDs: [UUID: Int64] = [:]
    private var searchTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var viewStatePersistTasks: [UUID: Task<Void, Never>] = [:]
    private var isRestoringState = false

    var recoveryStore: RecoveryStore {
        if let root = libraryRoot?.url { return .forLibrary(root: root) }
        return .standalone
    }

    init() {
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
        libraryRoot = root
        refreshFolderTree()

        Task {
            do {
                let store = try LibraryStore.forLibrary(root: root.url)
                self.store = store
                let indexer = LibraryIndexer(root: root.url, store: store) {
                    Task { @MainActor in
                        AppModelChangeRelay.shared.libraryDidChange()
                    }
                }
                self.indexer = indexer
                AppModelChangeRelay.shared.register(self)
                await restoreUIState()
                try await indexer.start()
                refreshFileList()
            } catch {
                openError = "Couldn’t open the library index: \(error.localizedDescription)"
            }
        }
    }

    private func detachLibrary() {
        let oldIndexer = indexer
        let oldStore = store
        let oldRoot = libraryRoot
        indexer = nil
        store = nil
        libraryRoot = nil
        searchTask?.cancel()
        searchTask = nil
        persistTask?.cancel()
        persistTask = nil
        for task in viewStatePersistTasks.values { task.cancel() }
        viewStatePersistTasks = [:]
        for session in tabs {
            session.close()
            SessionRegistry.shared.unregister(session)
        }
        tabs = []
        activeTabID = nil
        sessionFileIDs = [:]
        folderTree = nil
        Task {
            await oldIndexer?.stop()
            try? await oldStore?.close()
            oldRoot?.stopAccessing()
        }
    }

    /// Called by the change relay whenever the indexer commits a batch.
    func libraryIndexDidChange() {
        refreshFileList()
        refreshFolderTree()
        if sidebarSelection == .search { scheduleSearch() }
    }

    func refreshFolderTree() {
        guard let root = libraryRoot?.url else {
            folderTree = nil
            return
        }
        Task {
            let tree = await Task.detached(priority: .userInitiated) {
                LibraryBrowser.folderTree(at: root)
            }.value
            self.folderTree = tree
        }
    }

    // MARK: - File lists

    func refreshFileList() {
        guard let store else {
            files = []
            return
        }
        let selection = sidebarSelection ?? .allFiles
        let order = sortOrder
        Task {
            do {
                switch selection {
                case .allFiles:
                    files = try await store.allFiles(sortedBy: order)
                case .favorites:
                    files = try await store.favorites()
                case .recents:
                    files = try await store.recents()
                case .search:
                    files = []
                case .folder(let url):
                    let relative = relativePath(of: url) ?? ""
                    files = try await store.files(inFolder: relative, sortedBy: order)
                }
            } catch {
                files = []
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        guard let store else { return }
        let query = searchQuery
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let results = (try? await store.search(query)) ?? []
            guard !Task.isCancelled else { return }
            searchResults = results
        }
    }

    // MARK: - Paths

    func absoluteURL(of record: FileRecord) -> URL? {
        libraryRoot?.url.appendingPathComponent(record.relativePath)
    }

    func relativePath(of url: URL) -> String? {
        guard let root = libraryRoot?.url else { return nil }
        let rootPath = AppSupportPaths.canonicalPath(of: root)
        let path = AppSupportPaths.canonicalPath(of: url)
        if path == rootPath { return "" }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// True when the given file lives inside the active library root.
    func contains(_ url: URL) -> Bool {
        guard let root = libraryRoot?.url else { return false }
        let rootPath = AppSupportPaths.canonicalPath(of: root) + "/"
        return AppSupportPaths.canonicalPath(of: url).hasPrefix(rootPath)
    }

    // MARK: - Tabs

    func openFile(at url: URL) {
        if let existing = tabs.first(where: { $0.fileURL == url }) {
            activateTab(existing.id)
            return
        }
        let store = self.store
        let recovery = recoveryStore
        Task {
            do {
                let session = try await DocumentSession.open(fileURL: url, recoveryStore: recovery)

                if let store, let relative = relativePath(of: url) {
                    try? await store.markOpened(relativePath: relative)
                    if let record = try? await store.record(forRelativePath: relative) {
                        sessionFileIDs[session.id] = record.id
                        if let saved = try? await store.viewState(forFileID: record.id) {
                            session.viewState = saved
                        }
                        configureViewStatePersistence(
                            for: session,
                            fileID: record.id
                        )
                    }
                }
                SessionRegistry.shared.register(session)
                captureActiveViewState()
                tabs.append(session)
                activeTabID = session.id
                openError = nil
                persistUIStateSoon()
            } catch {
                openError = "Couldn’t open “\(url.lastPathComponent)”: \(error.localizedDescription)"
            }
        }
    }

    func activateTab(_ id: UUID) {
        guard id != activeTabID else { return }
        captureActiveViewState()
        if let previous = activeSession {
            Task { await previous.save(reason: .losingFocus) }
        }
        activeTabID = id
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let session = tabs[index]
        if session.id == activeTabID {
            captureActiveViewState()
        }
        persistViewState(for: session)
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs[max(0, min(index, tabs.count - 1)), default: nil]?.id
        }
        Task {
            await session.save(reason: .losingFocus)
            session.close()
            SessionRegistry.shared.unregister(session)
        }
        persistUIStateSoon()
    }

    private func captureActiveViewState() {
        guard let session = activeSession else { return }
        persistViewState(for: session)
    }

    private func persistViewState(for session: DocumentSession) {
        guard let store, let fileID = sessionFileIDs[session.id] else { return }
        viewStatePersistTasks[session.id]?.cancel()
        viewStatePersistTasks[session.id] = nil
        let state = session.viewState
        Task { try? await store.saveViewState(state, forFileID: fileID) }
    }

    private func configureViewStatePersistence(
        for session: DocumentSession,
        fileID: Int64
    ) {
        session.viewStateDidChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.viewStatePersistTasks[session.id]?.cancel()
            let store = self.store
            let state = session.viewState
            self.viewStatePersistTasks[session.id] = Task {
                guard !Task.isCancelled else { return }
                try? await store?.saveViewState(state, forFileID: fileID)
            }
        }
    }

    // MARK: - File operations

    func newFile(language: LanguageID) {
        guard let folder = selectedFolderForCreation() else { return }
        let definition = LanguageDefinition.definition(for: language)
        let url = LibraryBrowser.availableURL(
            in: folder, baseName: "Untitled", ext: definition.preferredExtension
        )
        do {
            try SaveCoordinator.writeAtomically(Data(), to: url)
        } catch {
            openError = "Couldn’t create the file: \(error.localizedDescription)"
            return
        }
        openFile(at: url)
        refreshFileList()
    }

    func newFolder(named name: String) {
        guard let parent = selectedFolderForCreation() else { return }
        do {
            _ = try FileOperations.createFolder(named: name, in: parent)
            refreshFolderTree()
        } catch {
            openError = "Couldn’t create the folder: \(error.localizedDescription)"
        }
    }

    private func selectedFolderForCreation() -> URL? {
        if case .folder(let url) = sidebarSelection { return url }
        return libraryRoot?.url
    }

    func toggleFavorite(_ record: FileRecord) {
        guard let store else { return }
        Task {
            try? await store.setFavorite(!record.isFavorite, relativePath: record.relativePath)
            refreshFileList()
        }
    }

    func rename(_ record: FileRecord, to newName: String) {
        guard let url = absoluteURL(of: record), !newName.isEmpty,
              newName != record.name else { return }
        do {
            let newURL = try FileOperations.rename(url, to: newName)
            if let session = tabs.first(where: { $0.fileURL == url }) {
                session.fileWasMoved(to: newURL)
            }
            refreshFileList()
        } catch {
            openError = "Couldn’t rename: \(error.localizedDescription)"
        }
    }

    func duplicate(_ record: FileRecord) {
        guard let url = absoluteURL(of: record) else { return }
        do {
            _ = try FileOperations.duplicate(url)
            refreshFileList()
        } catch {
            openError = "Couldn’t duplicate: \(error.localizedDescription)"
        }
    }

    func moveToTrash(_ record: FileRecord) {
        guard let url = absoluteURL(of: record) else { return }
        do {
            if let session = tabs.first(where: { $0.fileURL == url }) {
                closeTab(session.id)
            }
            try FileOperations.trash(url)
            if let store {
                let path = record.relativePath
                Task {
                    try? await store.removeFile(relativePath: path)
                    refreshFileList()
                }
            }
        } catch {
            openError = "Couldn’t move to Trash: \(error.localizedDescription)"
        }
    }

    /// Drag-and-drop: move a file into a folder shown in the sidebar.
    func moveFile(at sourceURL: URL, into folder: URL) {
        guard contains(sourceURL), contains(folder) || folder == libraryRoot?.url else { return }
        do {
            let newURL = try FileOperations.move(sourceURL, into: folder)
            if let session = tabs.first(where: { $0.fileURL == sourceURL }) {
                session.fileWasMoved(to: newURL)
            }
            refreshFileList()
        } catch {
            openError = "Couldn’t move the file: \(error.localizedDescription)"
        }
    }

    // MARK: - UI state persistence

    private struct PersistedUIState: Codable {
        var openTabPaths: [String]
        var activeTabPath: String?
        var selectedFolderPath: String?
        var selectionKind: String
    }

    private func persistUIStateSoon() {
        guard !isRestoringState, let store else { return }
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
        let kind: String
        var folderPath: String?
        switch sidebarSelection {
        case .favorites: kind = "favorites"
        case .recents: kind = "recents"
        case .search: kind = "search"
        case .folder(let url):
            kind = "folder"
            folderPath = relativePath(of: url)
        default: kind = "allFiles"
        }
        return PersistedUIState(
            openTabPaths: tabs.compactMap { relativePath(of: $0.fileURL) },
            activeTabPath: activeSession.flatMap { relativePath(of: $0.fileURL) },
            selectedFolderPath: folderPath,
            selectionKind: kind
        )
    }

    private func restoreUIState() async {
        guard let store, let root = libraryRoot?.url else { return }
        guard let json = try? await store.appState(forKey: "windowState.v1"),
              let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(PersistedUIState.self, from: data)
        else { return }

        isRestoringState = true
        defer { isRestoringState = false }

        if let rawHTML = try? await store.appState(forKey: "allowRawHTML.v1") {
            allowRawHTML = rawHTML == "1"
        }

        switch state.selectionKind {
        case "favorites": sidebarSelection = .favorites
        case "recents": sidebarSelection = .recents
        case "folder":
            if let path = state.selectedFolderPath {
                sidebarSelection = .folder(root.appendingPathComponent(path))
            }
        default: sidebarSelection = .allFiles
        }

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
                    if let tab = tabs.first(where: { $0.fileURL == url }) {
                        activeTabID = tab.id
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }
}

extension Array {
    /// Bounds-tolerant subscript used when picking a neighbor tab.
    subscript(index: Int, default defaultValue: Element?) -> Element? {
        indices.contains(index) ? self[index] : defaultValue
    }
}

/// The indexer's onChange fires from arbitrary tasks; this relay hops to the
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
}
