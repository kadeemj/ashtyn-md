import Foundation
import Testing
@testable import AshtynMD

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ashtyn-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Atomic saves")
struct SaveCoordinatorTests {
    @Test func createsNewFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("new.md")

        let file = LoadedTextFile(text: "# Hello\n", encoding: .utf8(bom: false), lineEnding: .lf)
        try SaveCoordinator.writeAtomically(file, to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "# Hello\n")
    }

    @Test func overwritePreservesFormatByteForByte() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("doc.txt")

        // Seed a CRLF + UTF-8-BOM file, load it, edit it, save it back.
        var seed = Data([0xEF, 0xBB, 0xBF])
        seed.append(Data("line one\r\nline two\r\n".utf8))
        try seed.write(to: target)

        var loaded = try LoadedTextFile.load(from: target)
        #expect(loaded.text == "line one\nline two\n")
        #expect(loaded.encoding == .utf8(bom: true))
        #expect(loaded.lineEnding == .crlf)

        loaded.text += "line three\n"
        try SaveCoordinator.writeAtomically(loaded, to: target)

        var expected = Data([0xEF, 0xBB, 0xBF])
        expected.append(Data("line one\r\nline two\r\nline three\r\n".utf8))
        #expect(try Data(contentsOf: target) == expected)
    }

    @Test func leavesNoTemporaryFilesBehind() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("doc.md")
        for i in 0..<5 {
            let file = LoadedTextFile(text: "rev \(i)\n", encoding: .utf8(bom: false), lineEnding: .lf)
            try SaveCoordinator.writeAtomically(file, to: target)
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining == ["doc.md"])
    }

    @Test func contentHashIsStableAndDistinct() {
        let a = SaveCoordinator.contentHash(of: "same")
        let b = SaveCoordinator.contentHash(of: "same")
        let c = SaveCoordinator.contentHash(of: "different")
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 64)
    }
}

@Suite("Recovery store")
struct RecoveryStoreTests {
    @Test func snapshotRoundTripAndRemoval() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecoveryStore(directory: dir.appendingPathComponent("Recovery"))
        let docURL = dir.appendingPathComponent("note.md")

        #expect(store.snapshot(for: docURL) == nil)

        let snapshot = RecoverySnapshot(
            originalPath: docURL.path,
            savedAt: Date(),
            text: "unsaved work",
            encoding: .utf8(bom: false),
            lineEnding: .lf
        )
        try store.writeSnapshot(snapshot, for: docURL)

        let restored = store.snapshot(for: docURL)
        #expect(restored?.text == "unsaved work")
        #expect(restored?.originalPath == docURL.path)

        store.removeSnapshot(for: docURL)
        #expect(store.snapshot(for: docURL) == nil)
    }

    @Test func snapshotsAreKeyedPerDocument() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecoveryStore(directory: dir.appendingPathComponent("Recovery"))
        let docA = dir.appendingPathComponent("a.md")
        let docB = dir.appendingPathComponent("b.md")

        try store.writeSnapshot(
            RecoverySnapshot(originalPath: docA.path, savedAt: Date(), text: "A",
                             encoding: .utf8(bom: false), lineEnding: .lf),
            for: docA
        )
        #expect(store.snapshot(for: docA)?.text == "A")
        #expect(store.snapshot(for: docB) == nil)
    }
}

@Suite("Document sessions")
@MainActor
struct DocumentSessionTests {
    private func makeSession(
        initialText: String = "hello\n"
    ) throws -> (DocumentSession, URL, URL) {
        let dir = try makeTempDirectory()
        let docURL = dir.appendingPathComponent("doc.md")
        try Data(initialText.utf8).write(to: docURL)
        let store = RecoveryStore(directory: dir.appendingPathComponent("Recovery"))
        let session = DocumentSession(
            fileURL: docURL,
            file: try LoadedTextFile.load(from: docURL),
            recoveryStore: store
        )
        return (session, docURL, dir)
    }

    @Test func oversizedFileRequiresExplicitSafeguardedOverride() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let docURL = dir.appendingPathComponent("large.md")
        _ = FileManager.default.createFile(atPath: docURL.path, contents: Data())
        let handle = try FileHandle(forWritingTo: docURL)
        try handle.truncate(atOffset: 10 * 1024 * 1024 + 1)
        try handle.close()
        let session = DocumentSession(
            fileURL: docURL,
            file: LoadedTextFile(
                text: "",
                encoding: .utf8(bom: false),
                lineEnding: .lf
            ),
            recoveryStore: RecoveryStore(
                directory: dir.appendingPathComponent("Recovery")
            )
        )

        #expect(session.capabilities.tier == .readOnlyLarge)
        #expect(!session.capabilities.isEditable)

        session.openLargeFileAnyway()

        #expect(session.capabilities.tier == .large)
        #expect(session.capabilities.isEditable)
        #expect(!session.capabilities.allowsAICompletion)
    }

    @Test func successfulSaveRefreshesFileSizeCapabilities() async throws {
        let (session, _, dir) = try makeSession(initialText: "")
        defer { try? FileManager.default.removeItem(at: dir) }

        session.updateText(
            String(
                repeating: "x",
                count: Int(DocumentCapabilities.fullFeatureByteLimit) + 1
            )
        )
        await session.save(reason: .explicit)

        #expect(session.capabilities.tier == .large)
        #expect(session.capabilities.previewBehavior == .manual)
    }

    @Test func editMarksDirtyAndSaveWritesThrough() async throws {
        let (session, docURL, dir) = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(!session.isDirty)
        session.updateText("hello world\n")
        #expect(session.isDirty)

        await session.save(reason: .explicit)
        #expect(!session.isDirty)
        #expect(try String(contentsOf: docURL, encoding: .utf8) == "hello world\n")
    }

    @Test func revertingToSavedContentClearsDirty() throws {
        let (session, _, dir) = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        session.updateText("changed")
        #expect(session.isDirty)
        session.updateText("hello\n")
        #expect(!session.isDirty)
    }

    @Test func externalEditWithoutLocalChangesReloads() async throws {
        let (session, docURL, dir) = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Backdate the session's knowledge, then change the file on disk.
        try Data("external content\n".utf8).write(to: docURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: docURL.path
        )
        session.checkForExternalChanges()
        #expect(session.text == "external content\n")
        #expect(session.conflict == .none)
        #expect(!session.isDirty)
    }

    @Test func overlappingEditsBecomeAConflictAndAreNeverOverwritten() async throws {
        let (session, docURL, dir) = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        session.updateText("my local edit\n")
        try Data("external content\n".utf8).write(to: docURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: docURL.path
        )

        session.checkForExternalChanges()
        #expect(session.conflict == .externalChange)

        // A save in conflict state must not touch the disk file.
        await session.save(reason: .autosave)
        #expect(try String(contentsOf: docURL, encoding: .utf8) == "external content\n")

        // Keep Mine explicitly overwrites.
        await session.resolveConflictKeepingMine()
        #expect(session.conflict == .none)
        #expect(try String(contentsOf: docURL, encoding: .utf8) == "my local edit\n")
    }

    @Test func missingFileIsDetectedAndRestorable() async throws {
        let (session, docURL, dir) = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        session.updateText("survivor\n")
        try FileManager.default.removeItem(at: docURL)
        session.checkForExternalChanges()
        #expect(session.conflict == .fileMissing)

        await session.restoreMissingFile()
        #expect(session.conflict == .none)
        #expect(try String(contentsOf: docURL, encoding: .utf8) == "survivor\n")
    }

    @Test func newerRecoverySnapshotIsOfferedOnOpen() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let docURL = dir.appendingPathComponent("doc.md")
        try Data("saved state\n".utf8).write(to: docURL)
        let store = RecoveryStore(directory: dir.appendingPathComponent("Recovery"))

        try store.writeSnapshot(
            RecoverySnapshot(
                originalPath: docURL.path,
                savedAt: Date().addingTimeInterval(60),
                text: "unsaved newer state\n",
                encoding: .utf8(bom: false),
                lineEnding: .lf
            ),
            for: docURL
        )

        let session = DocumentSession(
            fileURL: docURL,
            file: try LoadedTextFile.load(from: docURL),
            recoveryStore: store
        )
        #expect(session.pendingRecovery?.text == "unsaved newer state\n")

        session.acceptPendingRecovery()
        #expect(session.text == "unsaved newer state\n")
        #expect(session.isDirty)
    }

    @Test func staleRecoverySnapshotIsDiscardedOnOpen() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let docURL = dir.appendingPathComponent("doc.md")
        try Data("saved state\n".utf8).write(to: docURL)
        let store = RecoveryStore(directory: dir.appendingPathComponent("Recovery"))

        try store.writeSnapshot(
            RecoverySnapshot(
                originalPath: docURL.path,
                savedAt: Date().addingTimeInterval(-3600),
                text: "old stale state\n",
                encoding: .utf8(bom: false),
                lineEnding: .lf
            ),
            for: docURL
        )

        let session = DocumentSession(
            fileURL: docURL,
            file: try LoadedTextFile.load(from: docURL),
            recoveryStore: store
        )
        #expect(session.pendingRecovery == nil)
        #expect(store.snapshot(for: docURL) == nil)
    }
}
