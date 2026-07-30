import Foundation
import Testing
@testable import AshtynMD

@Suite("External sync stress")
@MainActor
struct ExternalSyncStressTests {
    private func makeSession()
        throws -> (session: DocumentSession, document: URL, directory: URL)
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashtyn-sync-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let document = directory.appendingPathComponent("note.md")
        try Data("original\n".utf8).write(to: document)
        let store = RecoveryStore(
            directory: directory.appendingPathComponent("Recovery")
        )
        let session = DocumentSession(
            fileURL: document,
            file: try LoadedTextFile.load(from: document),
            recoveryStore: store
        )
        return (session, document, directory)
    }

    private func replace(
        _ url: URL,
        with text: String,
        generation: Int
    ) throws {
        try SaveCoordinator.writeAtomically(
            LoadedTextFile(
                text: text,
                encoding: .utf8(bom: false),
                lineEnding: .lf
            ),
            to: url
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(Double(generation + 1))],
            ofItemAtPath: url.path
        )
    }

    @Test func repeatedMetadataTouchesDoNotCreateAConflict() throws {
        let fixture = try makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        for generation in 0..<20 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(generation + 1))],
                ofItemAtPath: fixture.document.path
            )
            fixture.session.checkForExternalChanges()
            #expect(fixture.session.conflict == .none)
            #expect(fixture.session.text == "original\n")
        }
    }

    @Test func rapidAtomicReplacementsReloadTheNewestCleanVersion() throws {
        let fixture = try makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        for generation in 0..<20 {
            try replace(
                fixture.document,
                with: "remote \(generation)\n",
                generation: generation
            )
            fixture.session.checkForExternalChanges()
        }

        #expect(fixture.session.text == "remote 19\n")
        #expect(fixture.session.conflict == .none)
        #expect(!fixture.session.isDirty)
    }

    @Test func dirtySessionNeverOverwritesRapidExternalReplacement() async throws {
        let fixture = try makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.session.updateText("local unsaved\n")

        for generation in 0..<20 {
            try replace(
                fixture.document,
                with: "remote \(generation)\n",
                generation: generation
            )
            fixture.session.checkForExternalChanges()
        }
        try await Task.sleep(
            for: DocumentSession.autosaveDelay + .milliseconds(200)
        )

        #expect(fixture.session.conflict == .externalChange)
        #expect(fixture.session.text == "local unsaved\n")
        #expect(
            try String(contentsOf: fixture.document, encoding: .utf8)
                == "remote 19\n"
        )
    }

    @Test func deleteThenRecreateCanBeReconciled() throws {
        let fixture = try makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try FileManager.default.removeItem(at: fixture.document)
        fixture.session.checkForExternalChanges()
        #expect(fixture.session.conflict == .fileMissing)

        try replace(fixture.document, with: "recreated\n", generation: 1)
        fixture.session.checkForExternalChanges()
        #expect(fixture.session.conflict == .none)
        #expect(fixture.session.text == "recreated\n")
        #expect(!fixture.session.isDirty)
    }
}
