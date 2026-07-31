import AppKit
import Testing

@testable import AshtynMD

/// Tests for the storage-attribute styling path.
///
/// These host a real `PlainTextView` in a real `NSWindow` because
/// `NSTextView.undoManager` is nil without one, and two of the load-bearing
/// guarantees here are about undo and dirty state.
@Suite("Markdown styler")
@MainActor
struct MarkdownStylerTests {
    private func makeEditor(_ text: String) -> (PlainTextView, MarkdownStyler) {
        let view = PlainTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isRichText = MarkdownStyler.requiresRichText
        view.allowsUndo = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView = view
        view.languageDefinition = LanguageDefinition.definition(for: .markdown)
        let profile = EditorProfile.defaultProfile(for: .markdown)
        view.profile = profile
        view.string = text

        let styler = MarkdownStyler(
            textView: view,
            profile: profile,
            palette: EditorTheme.system.palette(forDarkAppearance: false)
        )
        view.markdownStyler = styler
        styler.applyBaseAttributes()
        styler.restyleAll()
        return (view, styler)
    }

    private func attributes(_ view: PlainTextView, at location: Int) -> [NSAttributedString.Key: Any] {
        view.textStorage?.attributes(at: location, effectiveRange: nil) ?? [:]
    }

    private func font(_ view: PlainTextView, at location: Int) -> NSFont? {
        attributes(view, at: location)[.font] as? NSFont
    }

    private func color(_ view: PlainTextView, at location: Int) -> NSColor? {
        attributes(view, at: location)[.foregroundColor] as? NSColor
    }

    // MARK: - The isRichText spike

    @Test("programmatic storage attributes survive a selection change")
    func programmaticAttributesSurvive() {
        // NSTextView is documented to gate *user* attribute changes on
        // isRichText, but is also known to normalize typingAttributes from
        // self.font on some paths. Everything else in this gate rests on
        // programmatic font attributes sticking, so it is asserted directly.
        let (view, _) = makeEditor("# Heading\n\nbody text")
        let headingFont = font(view, at: 2)
        #expect(headingFont != nil)

        view.setSelectedRange(NSRange(location: 12, length: 0))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(font(view, at: 2)?.pointSize == headingFont?.pointSize)
    }

    // MARK: - Layout-affecting attributes

    @Test("headings get a real point size, not just a color")
    func headingsAreLarger() {
        let (view, _) = makeEditor("# Big\n\nbody")
        let profile = EditorProfile.defaultProfile(for: .markdown)
        let headingSize = font(view, at: 2)?.pointSize ?? 0
        let bodySize = font(view, at: 8)?.pointSize ?? 0
        #expect(headingSize > bodySize)
        #expect(abs(headingSize - profile.headingSize(level: 1)) < 0.01)
    }

    @Test("heading levels scale down")
    func headingLevelsScale() {
        let (view, _) = makeEditor("# One\n## Two\n### Three")
        let one = font(view, at: 2)?.pointSize ?? 0
        let two = font(view, at: 9)?.pointSize ?? 0
        let three = font(view, at: 18)?.pointSize ?? 0
        #expect(one > two)
        #expect(two > three)
    }

    @Test("bold and italic carry real font traits")
    func emphasisTraits() {
        let (view, _) = makeEditor("**bold** and *slanted* text")
        let boldTraits = font(view, at: 3)?.fontDescriptor.symbolicTraits ?? []
        #expect(boldTraits.contains(.bold))

        let italicTraits = font(view, at: 15)?.fontDescriptor.symbolicTraits ?? []
        #expect(italicTraits.contains(.italic))
    }

    @Test("inline code switches to the monospace family")
    func inlineCodeIsMonospaced() {
        let (view, _) = makeEditor("text `code` more")
        let codeFont = font(view, at: 7)
        let bodyFont = font(view, at: 1)
        #expect(codeFont?.familyName != bodyFont?.familyName)
    }

    @Test("blockquotes and lists get a hanging indent")
    func hangingIndent() {
        let (view, _) = makeEditor("> quoted line")
        let style = attributes(view, at: 3)[.paragraphStyle] as? NSParagraphStyle
        #expect((style?.headIndent ?? 0) > 0)

        let (listView, _) = makeEditor("- an item")
        let listStyle = attributes(listView, at: 3)[.paragraphStyle] as? NSParagraphStyle
        #expect((listStyle?.headIndent ?? 0) > 0)
    }

    @Test("tag runs get kerning so the pill has padding")
    func tagKerning() {
        let (view, _) = makeEditor("note #work here")
        let kern = attributes(view, at: 5)[.kern] as? NSNumber
        #expect((kern?.doubleValue ?? 0) > 0)
    }

    @Test("tag ranges are published for pill drawing")
    func tagRangesPublished() {
        let (view, styler) = makeEditor("note #work/alpha here")
        #expect(styler.tagRanges.count == 1)
        #expect((view.string as NSString).substring(with: styler.tagRanges[0]) == "#work/alpha")
    }

    // MARK: - Undo and dirty state

    @Test("restyling registers no undo")
    func restyleDoesNotRegisterUndo() {
        let (view, styler) = makeEditor("# Heading\n\nbody")
        view.undoManager?.removeAllActions()
        styler.restyleAll()
        #expect(view.undoManager?.canUndo == false)
    }

    @Test("restyling does not post a text-change notification")
    func restyleDoesNotDirtyTheDocument() {
        let (view, styler) = makeEditor("# Heading\n\nbody")
        var changes = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: view, queue: nil
        ) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        styler.restyleAll()
        styler.restyle(afterEditIn: NSRange(location: 0, length: 9))
        #expect(changes == 0)
    }

    @Test("an edit restyles its block and the visible window, not the document")
    func incrementalRestyle() {
        // Long enough that the visible window is a small fraction of it —
        // on a fully-visible short document restyling everything is correct,
        // so the incremental path is only observable at scale.
        let block = "## Section\n\nSome **bold** body text with a `code` span.\n\n"
        let (view, styler) = makeEditor(String(repeating: block, count: 120))
        let length = (view.string as NSString).length

        styler.resetRestyleLog()
        view.textStorage?.replaceCharacters(in: NSRange(location: 20, length: 0), with: "X")
        styler.restyle(afterEditIn: NSRange(location: 20, length: 1))

        #expect(!styler.restyledRanges.isEmpty)
        let total = styler.restyledRanges.reduce(0) { $0 + $1.length }
        #expect(total < length, "restyled \(total) of \(length)")
    }

    @Test("styling survives an edit")
    func stylingSurvivesEdit() {
        let (view, styler) = makeEditor("# One\n\nbody")
        view.textStorage?.replaceCharacters(in: NSRange(location: 5, length: 0), with: " more")
        styler.restyle(afterEditIn: NSRange(location: 5, length: 5))
        // The heading still reads as a heading after being typed into.
        #expect((font(view, at: 2)?.pointSize ?? 0) > (font(view, at: 13)?.pointSize ?? 0))
    }

    // MARK: - Marker visibility

    @Test("markers dim off the caret line and brighten on it")
    func caretLineReveal() {
        let (view, styler) = makeEditor("# Heading\n\nbody text")
        view.setSelectedRange(NSRange(location: 14, length: 0))
        styler.selectionDidChange(to: view.selectedRange())
        let dimmed = color(view, at: 0)

        view.setSelectedRange(NSRange(location: 3, length: 0))
        styler.selectionDidChange(to: view.selectedRange())
        let revealed = color(view, at: 0)

        #expect(dimmed != revealed)
    }

    @Test("marker visibility always keeps markers at full strength")
    func alwaysVisibleMarkers() {
        let (view, styler) = makeEditor("# Heading\n\nbody text")
        var profile = EditorProfile.defaultProfile(for: .markdown)
        profile.markerVisibility = .always
        styler.profile = profile

        view.setSelectedRange(NSRange(location: 14, length: 0))
        styler.selectionDidChange(to: view.selectedRange())
        let offLine = color(view, at: 0)

        view.setSelectedRange(NSRange(location: 3, length: 0))
        styler.selectionDidChange(to: view.selectedRange())
        #expect(color(view, at: 0) == offLine)
    }

    // MARK: - Focus mode

    @Test("focus mode dims paragraphs away from the caret")
    func focusModeDims() {
        let (view, styler) = makeEditor("first paragraph\n\nsecond paragraph\n\nthird paragraph")
        view.setSelectedRange(NSRange(location: 20, length: 0))
        styler.selectionDidChange(to: view.selectedRange())
        styler.focusModeEnabled = true

        let layoutManager = view.layoutManager
        let dimmedAway = layoutManager?.temporaryAttribute(
            .foregroundColor, atCharacterIndex: 2, effectiveRange: nil
        ) as? NSColor
        let focused = layoutManager?.temporaryAttribute(
            .foregroundColor, atCharacterIndex: 20, effectiveRange: nil
        ) as? NSColor

        #expect(dimmedAway != nil)
        #expect(focused == nil)
    }

    @Test("turning focus mode off clears the dim")
    func focusModeClears() {
        let (view, styler) = makeEditor("first\n\nsecond\n\nthird")
        styler.focusModeEnabled = true
        styler.focusModeEnabled = false
        let dimmed = view.layoutManager?.temporaryAttribute(
            .foregroundColor, atCharacterIndex: 0, effectiveRange: nil
        )
        #expect(dimmed == nil)
    }

    // MARK: - Typing attributes

    @Test("typing inside a bold run continues bold")
    func typingAttributesInsideBold() {
        let (view, styler) = makeEditor("**bold** text")
        let inside = styler.typingAttributes(at: 4)
        let insideFont = inside[.font] as? NSFont
        #expect(insideFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)

        let outside = styler.typingAttributes(at: 11)
        let outsideFont = outside[.font] as? NSFont
        #expect(outsideFont?.fontDescriptor.symbolicTraits.contains(.bold) != true)
    }

    @Test("typing on a heading line continues the heading size")
    func typingAttributesOnHeading() {
        let (_, styler) = makeEditor("# Heading\n\nbody")
        let heading = styler.typingAttributes(at: 6)[.font] as? NSFont
        let body = styler.typingAttributes(at: 13)[.font] as? NSFont
        #expect((heading?.pointSize ?? 0) > (body?.pointSize ?? 0))
    }

    // MARK: - Code documents are untouched

    @Test("a code document keeps one uniform font")
    func codeDocumentsAreUniform() {
        let view = PlainTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView = view
        view.languageDefinition = LanguageDefinition.definition(for: .swift)
        view.profile = EditorProfile.defaultProfile(for: .swift)
        view.string = "# not a heading\nlet x = 1"
        #expect(view.markdownStyler == nil)
    }
}
