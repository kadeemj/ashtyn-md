import Foundation
import Observation

/// Open document tabs and the per-file view state that rides along with them.
@MainActor
@Observable
final class TabsModel {
    private(set) var tabs: [DocumentSession] = []
    var activeTabID: UUID? {
        didSet {
            guard activeTabID != oldValue else { return }
            onTabsChange?()
        }
    }

    var activeSession: DocumentSession? {
        tabs.first { $0.id == activeTabID }
    }

    /// Fired when tabs or the active tab change, so UI state gets persisted.
    var onTabsChange: (() -> Void)?
    /// Surfaces a user-visible failure without this model knowing about the UI.
    var onError: ((String) -> Void)?
    /// Called after a session's text changes, for title-driven renaming.
    var onSessionTextChange: ((DocumentSession) -> Void)?

    /// Session id → indexed file id, for view-state persistence.
    private var sessionFileIDs: [UUID: Int64] = [:]
    private var viewStatePersistTasks: [UUID: Task<Void, Never>] = [:]

    func fileID(for session: DocumentSession) -> Int64? {
        sessionFileIDs[session.id]
    }

    func session(forURL url: URL) -> DocumentSession? {
        tabs.first { $0.fileURL == url }
    }

    // MARK: - Opening

    func open(url: URL, using session: LibrarySession) {
        if let existing = tabs.first(where: { $0.fileURL == url }) {
            activate(existing.id)
            return
        }
        let store = session.store
        let recovery = session.recoveryStore
        let relative = session.relativePath(of: url)

        Task {
            do {
                let document = try await DocumentSession.open(
                    fileURL: url, recoveryStore: recovery
                )

                if let store, let relative {
                    try? await store.markOpened(relativePath: relative)
                    if let record = try? await store.record(forRelativePath: relative) {
                        sessionFileIDs[document.id] = record.id
                        if let saved = try? await store.viewState(forFileID: record.id) {
                            document.viewState = saved
                        }
                        configureViewStatePersistence(
                            for: document, fileID: record.id, store: store
                        )
                    }
                }
                document.textDidChange = { [weak self, weak document] in
                    guard let self, let document else { return }
                    self.onSessionTextChange?(document)
                }
                SessionRegistry.shared.register(document)
                captureActiveViewState()
                tabs.append(document)
                activeTabID = document.id
                onTabsChange?()
            } catch {
                onError?("Couldn’t open “\(url.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
    }

    func activate(_ id: UUID) {
        guard id != activeTabID else { return }
        captureActiveViewState()
        if let previous = activeSession {
            Task { await previous.save(reason: .losingFocus) }
        }
        activeTabID = id
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let document = tabs[index]
        if document.id == activeTabID {
            captureActiveViewState()
        }
        persistViewState(for: document)
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs[max(0, min(index, tabs.count - 1)), default: nil]?.id
        }
        sessionFileIDs[document.id] = nil
        viewStatePersistTasks[document.id]?.cancel()
        viewStatePersistTasks[document.id] = nil
        Task {
            await document.save(reason: .losingFocus)
            document.close()
            SessionRegistry.shared.unregister(document)
        }
        onTabsChange?()
    }

    /// Closes everything, for library detach.
    func closeAll() {
        for task in viewStatePersistTasks.values { task.cancel() }
        viewStatePersistTasks = [:]
        for document in tabs {
            document.close()
            SessionRegistry.shared.unregister(document)
        }
        tabs = []
        activeTabID = nil
        sessionFileIDs = [:]
    }

    /// Retargets an open tab after the file moved on disk.
    func noteFileMoved(from oldURL: URL, to newURL: URL) {
        tabs.first { $0.fileURL == oldURL }?.fileWasMoved(to: newURL)
    }

    // MARK: - View state

    private func captureActiveViewState() {
        guard let document = activeSession else { return }
        persistViewState(for: document)
    }

    private func persistViewState(for document: DocumentSession) {
        guard let fileID = sessionFileIDs[document.id], let store = storeForPersistence else {
            return
        }
        viewStatePersistTasks[document.id]?.cancel()
        viewStatePersistTasks[document.id] = nil
        let state = document.viewState
        Task { try? await store.saveViewState(state, forFileID: fileID) }
    }

    /// Set by the composition root on attach; view-state writes need it after
    /// the owning session may already have been torn down.
    var storeForPersistence: LibraryStore?

    private func configureViewStatePersistence(
        for document: DocumentSession,
        fileID: Int64,
        store: LibraryStore
    ) {
        document.viewStateDidChange = { [weak self, weak document] in
            guard let self, let document else { return }
            self.viewStatePersistTasks[document.id]?.cancel()
            let state = document.viewState
            self.viewStatePersistTasks[document.id] = Task {
                guard !Task.isCancelled else { return }
                try? await store.saveViewState(state, forFileID: fileID)
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
