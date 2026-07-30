import Foundation
import Testing
@testable import AshtynMD

/// Indexer tests drive fullScan() directly — FSEvents delivery is exercised
/// manually and in UI tests, not here, to keep the suite deterministic.
@Suite("Library indexer")
struct LibraryIndexerTests {
    private func makeLibrary() throws -> (root: URL, store: LibraryStore, indexer: LibraryIndexer) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashtyn-index-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LibraryStore(
            databaseURL: root.appendingPathComponent(".index-test.sqlite")
        )
        let indexer = LibraryIndexer(root: root, store: store, onChange: {})
        return (root, store, indexer)
    }

    private func write(_ text: String, to name: String, in root: URL) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func withLibrary<T>(
        _ body: (URL, LibraryStore, LibraryIndexer) async throws -> T
    ) async throws -> T {
        let (root, store, indexer) = try makeLibrary()
        do {
            let result = try await body(root, store, indexer)
            await indexer.stop()
            try await store.close()
            try FileManager.default.removeItem(at: root)
            return result
        } catch {
            await indexer.stop()
            try? await store.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @Test func initialScanIndexesSupportedFiles() async throws {
        try await withLibrary { root, store, indexer in
            try write("# One", to: "one.md", in: root)
            try write("print('hi')", to: "code/two.py", in: root)
            try write("plain", to: "three.txt", in: root)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("empty-folder"), withIntermediateDirectories: true
            )

            try await indexer.fullScan()

            let paths = try await store.allFiles().map(\.relativePath).sorted()
            #expect(paths == ["code/two.py", "one.md", "three.txt"])

            let markdown = try await store.record(forRelativePath: "one.md")
            #expect(markdown?.languageID == .markdown)
            let python = try await store.record(forRelativePath: "code/two.py")
            #expect(python?.languageID == .python)
        }
    }

    @Test func excludedDirectoriesAreSkipped() async throws {
        try await withLibrary { root, store, indexer in
            try write("keep", to: "keep.md", in: root)
            try write("skip", to: ".git/config.md", in: root)
            try write("skip", to: "node_modules/pkg/readme.md", in: root)
            try write("skip", to: ".build/log.txt", in: root)
            try write("skip", to: "sub/DerivedData/x.md", in: root)
            try write("skip", to: ".hidden.md", in: root)

            try await indexer.fullScan()
            let paths = try await store.allFiles().map(\.relativePath)
            #expect(paths == ["keep.md"])
        }
    }

    @Test func rescanPicksUpEditsAndRemovals() async throws {
        try await withLibrary { root, store, indexer in
            try write("original body", to: "a.md", in: root)
            try write("goes away", to: "b.md", in: root)
            try await indexer.fullScan()
            #expect(try await store.fileCount() == 2)

            // Edit one (with a distinct mtime) and delete the other.
            try write("edited body with zanzibar", to: "a.md", in: root)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(5)],
                ofItemAtPath: root.appendingPathComponent("a.md").path
            )
            try FileManager.default.removeItem(at: root.appendingPathComponent("b.md"))

            try await indexer.fullScan()
            #expect(try await store.fileCount() == 1)
            let hits = try await store.search("zanzibar")
            #expect(hits.map(\.record.relativePath) == ["a.md"])
        }
    }

    @Test func moveIsRecognizedByResourceIdentifier() async throws {
        try await withLibrary { root, store, indexer in
            try write("movable", to: "start.md", in: root)
            try await indexer.fullScan()
            try await store.setFavorite(true, relativePath: "start.md")
            let originalID = try await store.record(forRelativePath: "start.md")?.id

            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("dest"), withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(
                at: root.appendingPathComponent("start.md"),
                to: root.appendingPathComponent("dest/renamed.md")
            )

            try await indexer.fullScan()
            let moved = try await store.record(forRelativePath: "dest/renamed.md")
            #expect(moved != nil)
            #expect(moved?.id == originalID)
            #expect(moved?.isFavorite == true)
            #expect(try await store.record(forRelativePath: "start.md") == nil)
        }
    }

    @Test func binaryContentIsExcludedFromFullText() async throws {
        try await withLibrary { root, store, indexer in
            // Extensionless file with NUL bytes: metadata indexed, content not.
            var binary = Data("binaryhaystack".utf8)
            binary.append(contentsOf: [0x00, 0x01, 0x02])
            try binary.write(to: root.appendingPathComponent("blob"))

            try await indexer.fullScan()
            #expect(try await store.record(forRelativePath: "blob") != nil)
            #expect(try await store.search("binaryhaystack").isEmpty)
        }
    }

    @Test func unchangedFilesAreNotReindexed() async throws {
        try await withLibrary { root, store, indexer in
            try write("stable", to: "same.md", in: root)
            try await indexer.fullScan()
            let before = try await store.record(forRelativePath: "same.md")

            try await indexer.fullScan()
            let after = try await store.record(forRelativePath: "same.md")
            #expect(before == after)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func scanAndSearchStayFastOnALargeLibrary() async throws {
        try await withLibrary { root, store, indexer in
            // A scaled-down stand-in for the 10k-file target; CI-friendly.
            for folder in 0..<20 {
                for file in 0..<75 {
                    try write(
                        "# Note \(folder)-\(file)\nbody text with needle\(folder)x\(file)\n",
                        to: "folder\(folder)/note\(file).md", in: root
                    )
                }
            }
            let scanStart = ContinuousClock.now
            try await indexer.fullScan()
            let scanDuration = ContinuousClock.now - scanStart
            #expect(try await store.fileCount() == 1500)

            let searchStart = ContinuousClock.now
            let hits = try await store.search("needle7x42")
            let searchDuration = ContinuousClock.now - searchStart
            #expect(hits.count == 1)
            // Spec target: search under 200 ms once indexed.
            #expect(searchDuration < .milliseconds(200), "search took \(searchDuration)")
            #expect(scanDuration < .seconds(30), "scan took \(scanDuration)")
        }
    }
}
