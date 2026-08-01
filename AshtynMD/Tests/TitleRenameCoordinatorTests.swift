import Foundation
import Testing

@testable import AshtynMD

@Suite("Title rename coordinator")
@MainActor
struct TitleRenameCoordinatorTests {
    @Test("an edited managed note saves before it is renamed")
    func savesThenRenames() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashtyn-title-rename-\(UUID().uuidString)", isDirectory: true)
        let supportRoot = AppSupportPaths.libraryDirectory(forRoot: root)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: supportRoot)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldURL = root.appendingPathComponent("draft.md")
        try Data("Old title\n\nbody".utf8).write(to: oldURL)

        let library = LibrarySession()
        _ = try library.attach(.unscoped(root))
        try await library.startIndexing()
        let document = try await DocumentSession.open(
            fileURL: oldURL,
            recoveryStore: library.recoveryStore
        )
        document.updateText("New: title\n\nbody")

        let coordinator = TitleRenameCoordinator(
            dependencies: .init(
                librarySession: { library },
                isEnabled: { true },
                isRestoringState: { false },
                noteFileMoved: { old, new in document.fileWasMoved(to: new); _ = old },
                didChangeFiles: {},
                reportError: { _ in }
            )
        )
        coordinator.schedule(for: document)
        try await Task.sleep(for: .seconds(1.6))

        let newURL = root.appendingPathComponent("New- title.md")
        #expect(FileManager.default.fileExists(atPath: newURL.path))
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(document.fileURL == newURL)
        #expect(String(data: try Data(contentsOf: newURL), encoding: .utf8) == "New: title\n\nbody")

        let previous = library.detach()
        await previous.indexer?.stop()
        try await previous.store?.close()
    }
}
