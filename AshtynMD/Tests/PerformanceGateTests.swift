import AppKit
import Darwin.Mach
import Foundation
import Testing
@testable import AshtynMD

@Suite(
    "Phase 6 performance gates",
    .enabled(
        if: ProcessInfo.processInfo.environment["ASHTYN_PERFORMANCE_TESTS"] == "1"
    )
)
struct PerformanceGateTests {
    private func makeLibrary()
        throws -> (root: URL, store: LibraryStore, indexer: LibraryIndexer)
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ashtyn-performance-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let store = try LibraryStore(
            databaseURL: root.appendingPathComponent(".performance.sqlite")
        )
        return (
            root,
            store,
            LibraryIndexer(root: root, store: store, onChange: {})
        )
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    @Test(.timeLimit(.minutes(2)))
    func tenThousandFileScanAndSearch() async throws {
        let fixture = try makeLibrary()
        do {
            for folder in 0..<100 {
                for file in 0..<100 {
                    try write(
                        "# Note \(folder)-\(file)\nneedle\(folder)x\(file)\n",
                        to: "folder\(folder)/note\(file).md",
                        in: fixture.root
                    )
                }
            }
            let scanStart = ContinuousClock.now
            try await fixture.indexer.fullScan()
            let scanDuration = ContinuousClock.now - scanStart
            #expect(try await fixture.store.fileCount() == 10_000)

            _ = try await fixture.store.search("needle73x42")
            let searchStart = ContinuousClock.now
            let hits = try await fixture.store.search("needle73x42")
            let searchDuration = ContinuousClock.now - searchStart
            #expect(
                hits.map(\.record.relativePath) == ["folder73/note42.md"]
            )
            #expect(searchDuration < .milliseconds(200))
            print("10k scan: \(scanDuration); search: \(searchDuration)")

            await fixture.indexer.stop()
            try await fixture.store.close()
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            await fixture.indexer.stop()
            try? await fixture.store.close()
            try? FileManager.default.removeItem(at: fixture.root)
            throw error
        }
    }

    @Test
    func hundredKilobyteMarkdownRendersUnderTarget() {
        let block =
            "# Heading\n\nA paragraph with **strong**, "
            + "[link](https://example.com), and `code`.\n\n"
        let repetitions = (100 * 1024 / block.utf8.count) + 1
        let markdown = String(repeating: block, count: repetitions)
        #expect(markdown.utf8.count >= 100 * 1024)

        let start = ContinuousClock.now
        _ = MarkdownHTMLRenderer(policy: .default).renderBody(markdown)
        let duration = ContinuousClock.now - start
        #expect(
            duration < .milliseconds(300),
            "render took \(duration)"
        )
    }

    @Test
    func visibleIncrementalSyntaxUpdateStaysUnderTarget() async {
        let highlighter = SyntaxHighlighter()
        let source = String(repeating: "let value = 42\n", count: 500)
        await highlighter.setLanguage(.swift)
        await highlighter.replaceText(source)
        _ = await highlighter.highlights(
            in: NSRange(location: 0, length: 2_000)
        )

        let insertion = "func added() { return }\n"
        let location = (source as NSString).length
        let insertionLength = (insertion as NSString).length
        let start = ContinuousClock.now
        await highlighter.applyEdit(
            newText: source + insertion,
            editedRange: NSRange(
                location: location,
                length: insertionLength
            ),
            delta: insertionLength,
            sequence: 1
        )
        _ = await highlighter.highlights(
            in: NSRange(
                location: max(0, location - 1_000),
                length: 1_000 + insertionLength
            )
        )
        let duration = ContinuousClock.now - start
        #expect(
            duration < .milliseconds(100),
            "syntax update took \(duration)"
        )
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    @Test
    @MainActor
    func twoMegabyteEditorEditAndLayoutStayUnderTarget() {
        let before = residentBytes()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        let textView = PlainTextView(frame: scrollView.bounds)
        _ = textView.layoutManager
        scrollView.documentView = textView
        window.contentView = scrollView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        let text = String(repeating: "let value = 42\n", count: 140_000)
        #expect(text.utf8.count >= 2 * 1024 * 1024)
        textView.string = text
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }

        let start = ContinuousClock.now
        textView.insertText(
            "x",
            replacementRange: NSRange(
                location: (text as NSString).length / 2,
                length: 0
            )
        )
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        let duration = ContinuousClock.now - start
        let after = residentBytes()
        print(
            "2 MB editor: \(duration); "
                + "resident before=\(before), after=\(after)"
        )
        #expect(
            duration < .milliseconds(100),
            "edit and layout took \(duration)"
        )
    }
}
