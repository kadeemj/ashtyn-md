import Foundation
import Observation

enum DocumentConflictState: Equatable, Sendable {
    case none
    /// Local edits and an external change overlap; autosave is paused.
    case externalChange
    /// The file disappeared from disk while open.
    case fileMissing
}

/// Editing state for one open file: content, byte-level format, dirty and
/// conflict tracking, autosave, and crash recovery. One instance per open
/// document; the canonical data is always the file itself.
@MainActor
@Observable
final class DocumentSession: Identifiable {
    nonisolated let id = UUID()

    private(set) var fileURL: URL
    private(set) var text: String
    private(set) var encoding: TextFileEncoding
    private(set) var lineEnding: LineEnding
    private(set) var languageID: LanguageID
    /// Explicit user language choice; beats every detection heuristic.
    private(set) var languageOverride: LanguageID?
    private(set) var isDirty = false
    private(set) var conflict: DocumentConflictState = .none
    private(set) var lastSaveError: String?
    /// A newer recovery snapshot found on open, awaiting a user decision.
    private(set) var pendingRecovery: RecoverySnapshot?
    /// File-size-derived editing, preview, and AI policy.
    private(set) var capabilities: DocumentCapabilities
    /// Live cursor/selection/scroll state, maintained by the editor view and
    /// persisted per-library on tab switches and closes. Observation-ignored:
    /// cursor movement must not invalidate SwiftUI views.
    @ObservationIgnored var viewState = FileViewState()
    /// Routes programmatic source edits (e.g. a preview checkbox toggle)
    /// through the live editor so they join the native undo stack. Registered
    /// by the editor coordinator; nil when no editor is mounted.
    @ObservationIgnored var sourceEditHandler: ((NSRange, String) -> Bool)?

    /// Applies a source edit, preferring the undoable editor path.
    func performSourceEdit(range: NSRange, replacement: String) {
        if let sourceEditHandler, sourceEditHandler(range, replacement) { return }
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length else { return }
        updateText(ns.replacingCharacters(in: range, with: replacement))
    }

    private var lastSavedHash: String
    private var lastKnownModificationDate: Date?
    private var fileResourceID: String?
    private var editRevision: UInt64 = 0
    private var autosaveTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private let recoveryStore: RecoveryStore
    private var openedLargeFileAnyway = false

    static let autosaveDelay: Duration = .milliseconds(700)
    static let snapshotInterval: Duration = .seconds(2)

    var displayName: String { fileURL.lastPathComponent }

    init(fileURL: URL, file: LoadedTextFile, recoveryStore: RecoveryStore) {
        self.fileURL = fileURL
        self.text = file.text
        self.encoding = file.encoding
        self.lineEnding = file.lineEnding
        self.languageID = LanguageDetector.detect(
            fileName: fileURL.lastPathComponent, contents: file.text
        )
        self.lastSavedHash = SaveCoordinator.contentHash(of: file.text)
        self.recoveryStore = recoveryStore
        self.capabilities = DocumentCapabilities(
            byteCount: Self.fileByteCount(at: fileURL)
        )

        let disk = SaveCoordinator.diskState(of: fileURL)
        self.lastKnownModificationDate = disk?.modificationDate
        self.fileResourceID = disk?.resourceID

        if let snapshot = recoveryStore.snapshot(for: fileURL),
           snapshot.text != file.text,
           let diskDate = disk?.modificationDate,
           snapshot.savedAt > diskDate {
            self.pendingRecovery = snapshot
        } else {
            recoveryStore.removeSnapshot(for: fileURL)
        }
    }

    /// Opens a file, reading and decoding it off the main actor.
    static func open(fileURL: URL, recoveryStore: RecoveryStore) async throws -> DocumentSession {
        let file = try await Task.detached(priority: .userInitiated) {
            try LoadedTextFile.load(from: fileURL)
        }.value
        return DocumentSession(fileURL: fileURL, file: file, recoveryStore: recoveryStore)
    }

    /// Explicitly enables editing for a file over 10 MB while retaining
    /// large-file safeguards. This decision lasts only for this session.
    func openLargeFileAnyway() {
        guard capabilities.tier == .readOnlyLarge else { return }
        openedLargeFileAnyway = true
        capabilities = capabilities.openingAnyway()
    }

    private static func fileByteCount(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func refreshCapabilities() {
        capabilities = DocumentCapabilities(
            byteCount: Self.fileByteCount(at: fileURL),
            openedAnyway: openedLargeFileAnyway
        )
    }

    // MARK: - Language

    func setLanguageOverride(_ override: LanguageID?) {
        languageOverride = override
        languageID = LanguageDetector.detect(
            fileName: fileURL.lastPathComponent, contents: text, override: override
        )
    }

    // MARK: - Editing

    /// Called by the editor whenever the document text changes.
    func updateText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        editRevision &+= 1
        isDirty = SaveCoordinator.contentHash(of: newText) != lastSavedHash
        lastSaveError = nil
        scheduleAutosave()
        startSnapshotLoopIfNeeded()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard conflict == .none else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: DocumentSession.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.save(reason: .autosave)
        }
    }

    private func startSnapshotLoopIfNeeded() {
        guard snapshotTask == nil, isDirty else { return }
        snapshotTask = Task { [weak self] in
            while let self, self.isDirty {
                self.writeRecoverySnapshot()
                try? await Task.sleep(for: DocumentSession.snapshotInterval)
                if Task.isCancelled { break }
            }
            self?.snapshotTask = nil
        }
    }

    private func writeRecoverySnapshot() {
        let snapshot = RecoverySnapshot(
            originalPath: fileURL.path,
            savedAt: Date(),
            text: text,
            encoding: encoding,
            lineEnding: lineEnding
        )
        try? recoveryStore.writeSnapshot(snapshot, for: fileURL)
    }

    // MARK: - Saving

    enum SaveReason: Sendable {
        case autosave
        case explicit
        case losingFocus
        case termination
    }

    func save(reason: SaveReason) async {
        guard isDirty else { return }
        checkForExternalChanges()
        // Autosave never overwrites a detected conflict; an explicit user
        // action ("Keep Mine") goes through performWrite() directly.
        guard conflict == .none else { return }
        await performWrite()
    }

    /// The write itself, without the external-change pre-check. Conflict
    /// resolutions call this directly because the user has already decided
    /// the local content should win.
    private func performWrite() async {
        let revision = editRevision
        let file = LoadedTextFile(text: text, encoding: encoding, lineEnding: lineEnding)
        let url = fileURL
        do {
            try await Task.detached(priority: .userInitiated) {
                try SaveCoordinator.writeAtomically(file, to: url)
            }.value
            lastSavedHash = SaveCoordinator.contentHash(of: file.text)
            let disk = SaveCoordinator.diskState(of: url)
            lastKnownModificationDate = disk?.modificationDate
            fileResourceID = disk?.resourceID
            refreshCapabilities()
            if editRevision == revision {
                isDirty = false
                snapshotTask?.cancel()
                snapshotTask = nil
                // Remove recovery data only after the save verifiably landed.
                if disk != nil {
                    recoveryStore.removeSnapshot(for: url)
                }
            }
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    /// Synchronous best-effort save used only at application termination,
    /// when no run loop remains to await an async save.
    func saveBlockingForTermination() {
        guard isDirty, conflict == .none else { return }
        let file = LoadedTextFile(text: text, encoding: encoding, lineEnding: lineEnding)
        do {
            try SaveCoordinator.writeAtomically(file, to: fileURL)
            lastSavedHash = SaveCoordinator.contentHash(of: file.text)
            isDirty = false
            recoveryStore.removeSnapshot(for: fileURL)
        } catch {
            // Leave the recovery snapshot in place; it restores on relaunch.
            writeRecoverySnapshot()
        }
    }

    // MARK: - External changes and conflicts

    /// Reconciles with the state of the file on disk. Called on window
    /// activation and before every save.
    func checkForExternalChanges() {
        guard let disk = SaveCoordinator.diskState(of: fileURL) else {
            if conflict != .fileMissing {
                conflict = .fileMissing
                autosaveTask?.cancel()
            }
            return
        }
        if conflict == .fileMissing {
            conflict = .none
        }
        guard let known = lastKnownModificationDate, disk.modificationDate > known else { return }

        guard let diskFile = try? LoadedTextFile.load(from: fileURL) else { return }
        let diskHash = SaveCoordinator.contentHash(of: diskFile.text)
        if diskHash == lastSavedHash {
            // Metadata-only change (e.g. a sync service touched the file).
            lastKnownModificationDate = disk.modificationDate
            return
        }
        if !isDirty {
            adopt(diskFile, modificationDate: disk.modificationDate, resourceID: disk.resourceID)
        } else {
            conflict = .externalChange
            autosaveTask?.cancel()
        }
    }

    private func adopt(_ file: LoadedTextFile, modificationDate: Date?, resourceID: String?) {
        text = file.text
        encoding = file.encoding
        lineEnding = file.lineEnding
        lastSavedHash = SaveCoordinator.contentHash(of: file.text)
        lastKnownModificationDate = modificationDate
        fileResourceID = resourceID
        isDirty = false
        conflict = .none
        editRevision &+= 1
        refreshCapabilities()
        recoveryStore.removeSnapshot(for: fileURL)
    }

    /// Conflict resolution: discard local edits and take the disk version.
    func resolveConflictUsingDisk() {
        guard let diskFile = try? LoadedTextFile.load(from: fileURL) else { return }
        let disk = SaveCoordinator.diskState(of: fileURL)
        adopt(diskFile, modificationDate: disk?.modificationDate, resourceID: disk?.resourceID)
    }

    /// Conflict resolution: overwrite the disk version with local edits.
    func resolveConflictKeepingMine() async {
        conflict = .none
        isDirty = true
        await performWrite()
    }

    /// The file vanished; write local content back to its original location.
    func restoreMissingFile() async {
        conflict = .none
        isDirty = true
        await performWrite()
    }

    /// Writes the current (or conflicted) content to a user-chosen location.
    func saveCopy(to destination: URL) async throws {
        let file = LoadedTextFile(text: text, encoding: encoding, lineEnding: lineEnding)
        try await Task.detached(priority: .userInitiated) {
            try SaveCoordinator.writeAtomically(file, to: destination)
        }.value
    }

    // MARK: - Recovery decisions

    func acceptPendingRecovery() {
        guard let snapshot = pendingRecovery else { return }
        pendingRecovery = nil
        updateText(snapshot.text)
    }

    func discardPendingRecovery() {
        pendingRecovery = nil
        recoveryStore.removeSnapshot(for: fileURL)
    }

    /// Called when the file is renamed or moved by the app itself.
    func fileWasMoved(to newURL: URL) {
        recoveryStore.removeSnapshot(for: fileURL)
        fileURL = newURL
        if isDirty { writeRecoverySnapshot() }
        let disk = SaveCoordinator.diskState(of: newURL)
        lastKnownModificationDate = disk?.modificationDate
        fileResourceID = disk?.resourceID
        refreshCapabilities()
    }

    func close() {
        autosaveTask?.cancel()
        snapshotTask?.cancel()
        snapshotTask = nil
    }
}
