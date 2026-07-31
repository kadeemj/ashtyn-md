import AppKit
import Testing

@testable import AshtynMD

/// Renders a styled Markdown document through real TextKit layout and writes a
/// PNG, so the inline styling can be eyeballed without launching the app.
///
/// Opt-in, like the performance gates: set `ASHTYN_SNAPSHOT=1` and read the
/// path the test prints. Nothing here asserts pixels — it exists so a human (or
/// an agent) can look at the result, which is the one thing the attribute
/// assertions in MarkdownStylerTests cannot cover.
@Suite(
    "Markdown styler snapshots",
    .enabled(if: ProcessInfo.processInfo.environment["ASHTYN_SNAPSHOT"] == "1")
)
@MainActor
struct MarkdownStylerSnapshotTests {
    private static let sample = """
    # Bear-like Formatting

    A paragraph with **bold text**, *italic text*, ***both at once***,
    `inline code`, ~~struck through~~, and a [link](https://example.com).

    Tags live in the text: #work/alpha and #reading

    ## Second Level Heading

    ### Third Level Heading

    - a bullet item
    - another bullet with **bold** inside
    - [ ] an open task
    - [x] a finished task

    1. first numbered
    2. second numbered

    > A blockquote line.
    > A second quoted line with *emphasis*.

    ```swift
    // A fenced code block — #notatag in here
    let answer = 42
    ```

    A wiki link to [[Fixture Note]] resolves inside the library.

    ---

    Final paragraph after a divider.
    """

    private func render(themeID: String, to url: URL) throws {
        let size = NSSize(width: 720, height: 1_150)
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        let textView = PlainTextView(frame: NSRect(origin: .zero, size: size))
        _ = textView.layoutManager
        textView.isRichText = MarkdownStyler.requiresRichText
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: size.width, height: .greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView = scrollView

        let theme = EditorTheme.theme(withID: themeID)
        let palette = theme.palette(forDarkAppearance: themeID != "light")
        let profile = EditorProfile.defaultProfile(for: .markdown)

        textView.languageDefinition = LanguageDefinition.definition(for: .markdown)
        textView.profile = profile
        textView.palette = palette
        textView.drawsBackground = true
        textView.backgroundColor = palette.background.nsColor
        textView.insertionPointColor = palette.caret.nsColor
        textView.string = Self.sample

        let styler = MarkdownStyler(textView: textView, profile: profile, palette: palette)
        textView.markdownStyler = styler
        styler.applyBaseAttributes()
        styler.restyleAll()

        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        guard let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else {
            Issue.record("could not create a bitmap rep")
            return
        }
        textView.cacheDisplay(in: textView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            Issue.record("could not encode PNG")
            return
        }
        try data.write(to: url)
    }

    @Test("renders the light and dark themes to PNGs")
    func renderSnapshots() throws {
        // The test host is sandboxed, so /tmp is not writable; the container's
        // temporary directory is.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashtyn-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for themeID in ["light", "dark"] {
            let url = directory.appendingPathComponent("markdown-\(themeID).png")
            try render(themeID: themeID, to: url)
            print("SNAPSHOT \(url.path)")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
