import AppKit

/// Owns `NSTextStorage` attributes for a Markdown document.
///
/// The code path keeps using `NSLayoutManager` temporary attributes, which is
/// right for it: syntax highlighting only varies color. Markdown cannot use
/// them, because temporary attributes are applied at draw time and are ignored
/// for glyph metrics — real heading sizes, bold weight, and hanging indents are
/// unreachable from there. So the two paths are strictly separated: Markdown
/// writes storage attributes and no temporary ones except the focus dim; code
/// writes temporary ones and never comes here.
@MainActor
final class MarkdownStyler {
    /// Whether the text view must opt into rich text for programmatic
    /// attributes to stick. Verified false — NSTextView honors storage
    /// attributes set in code with `isRichText = false`, which is preferable
    /// because it also keeps the user from pasting styled text in.
    static let requiresRichText = false

    /// Synchronous restyle budget. Anything larger defers to the async path so
    /// a big paste cannot stall a keystroke.
    private static let synchronousLimit = 8_192
    /// Visible-range padding, so scrolling a little does not trigger work.
    private static let visibleMargin = 500

    private weak var textView: PlainTextView?

    var profile: EditorProfile {
        didSet {
            guard profile != oldValue else { return }
            applyBaseAttributes()
            restyleAll()
        }
    }

    var palette: EditorPalette {
        didSet {
            guard palette != oldValue else { return }
            applyBaseAttributes()
            restyleAll()
        }
    }

    var focusModeEnabled: Bool = false {
        didSet {
            guard focusModeEnabled != oldValue else { return }
            applyFocusDim()
        }
    }

    /// Full tag spans in the styled region, consumed by the pill drawing in
    /// `PlainTextView.drawBackground(in:)`.
    private(set) var tagRanges: [NSRange] = []
    /// `[ ]` / `[x]` spans, for click hit-testing.
    private(set) var taskBracketRanges: [NSRange] = []
    /// Ranges restyled since the last `resetRestyleLog()`. Test observability
    /// for the incremental path.
    private(set) var restyledRanges: [NSRange] = []

    /// Block range currently rendered with markers revealed.
    private var revealedRange: NSRange?

    init(textView: PlainTextView, profile: EditorProfile, palette: EditorPalette) {
        self.textView = textView
        self.profile = profile
        self.palette = palette
        self.focusModeEnabled = profile.focusModeEnabled
    }

    private var builder: MarkdownAttributeBuilder {
        MarkdownAttributeBuilder(profile: profile, palette: palette)
    }

    func resetRestyleLog() {
        restyledRanges = []
    }

    // MARK: - Base attributes

    /// Sets the view-level defaults. Unlike the code path this does *not* stomp
    /// the whole storage with one font — `restyleAll` does that per block.
    func applyBaseAttributes() {
        guard let textView else { return }
        let builder = self.builder
        textView.font = MarkdownAttributeBuilder.font(
            named: profile.fontFamily, size: profile.fontSize
        )
        textView.defaultParagraphStyle = builder.paragraphStyle(for: nil)
        textView.typingAttributes = builder.baseAttributes()
    }

    // MARK: - Restyle

    func restyleAll() {
        guard let textView, let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        apply(scanResult(for: full, fenceState: false), to: full)
    }

    /// Restyles the block(s) touched by an edit, plus the visible window.
    ///
    /// The unit of work is a whole block because inline constructs cannot cross
    /// a blank line, so a block is the smallest region whose styling is
    /// self-contained.
    func restyle(afterEditIn editedRange: NSRange) {
        guard let textView, let storage = textView.textStorage else { return }
        let text = textView.string as NSString
        let dirty = blockRange(in: text, touching: editedRange)
        let target = union(dirty, visibleRange(padding: Self.visibleMargin))

        if target.length <= Self.synchronousLimit {
            apply(scanResult(for: target, fenceState: fenceState(at: target.location, in: text)), to: target)
        } else {
            // Style the edited block now so typing never looks unstyled, and
            // let the wider region catch up on the next pass.
            apply(scanResult(for: dirty, fenceState: fenceState(at: dirty.location, in: text)), to: dirty)
        }
        _ = storage
    }

    /// Restyles whatever is on screen. Driven from the scroll observer.
    func restyleVisible() {
        guard let textView else { return }
        let text = textView.string as NSString
        let target = visibleRange(padding: Self.visibleMargin)
        guard target.length > 0 else { return }
        apply(scanResult(for: target, fenceState: fenceState(at: target.location, in: text)), to: target)
    }

    private func scanResult(for range: NSRange, fenceState: Bool) -> MarkdownStyleResult {
        guard let textView else { return MarkdownStyleResult() }
        let text = textView.string as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard clamped.length > 0 || text.length == 0 else { return MarkdownStyleResult() }
        if clamped.length == text.length && clamped.location == 0 {
            return MarkdownStyleScanner.scan(text)
        }
        return MarkdownStyleScanner.scan(text, in: clamped, fenceState: fenceState)
    }

    /// Writes attributes for `result` over `range`.
    ///
    /// Wrapped in begin/endEditing and never routed through
    /// `shouldChangeText`/`didChangeText`, so styling registers no undo action
    /// and cannot mark the document dirty.
    private func apply(_ result: MarkdownStyleResult, to range: NSRange) {
        guard let textView, let storage = textView.textStorage else { return }
        let length = storage.length
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard clamped.length > 0 else {
            if length == 0 { tagRanges = []; taskBracketRanges = [] }
            return
        }

        let builder = self.builder
        let base = builder.baseAttributes()
        let reveal = revealedRange

        storage.beginEditing()
        storage.setAttributes(base, range: clamped)

        // Blocks first: paragraph style is per line and inline runs layer on top.
        var headingLevels: [Int: Int] = [:]
        for block in result.blocks {
            let blockRange = NSIntersectionRange(block.lineRange, clamped)
            guard blockRange.length > 0 else { continue }
            storage.addAttribute(
                .paragraphStyle, value: builder.paragraphStyle(for: block), range: blockRange
            )
            if case .heading(let level) = block.kind {
                headingLevels[block.lineRange.location] = level
                // Heading metrics apply to the whole line, markers included, so
                // revealing `##` cannot change the line height.
                let size = profile.headingSize(level: level)
                storage.addAttribute(
                    .font,
                    value: MarkdownAttributeBuilder.applying(
                        weight: profile.roleStyle(for: .heading).weight,
                        italic: false,
                        to: MarkdownAttributeBuilder.font(named: profile.fontFamily, size: size),
                        size: size
                    ),
                    range: blockRange
                )
            }
            if block.kind == .codeBlock {
                storage.addAttribute(
                    .font,
                    value: MarkdownAttributeBuilder.font(
                        named: profile.monospaceFontFamily,
                        size: profile.fontSize * profile.roleStyle(for: .codeBlock).sizeMultiple
                    ),
                    range: blockRange
                )
            }
        }

        for span in result.spans {
            let spanRange = NSIntersectionRange(span.range, clamped)
            guard spanRange.length > 0 else { continue }
            let revealed = reveal.map { NSIntersectionRange($0, span.range).length > 0 } ?? false
            if profile.markerVisibility != .always,
               !revealed,
               builder.isMarker(span.role),
               profile.markerVisibility == .hidden {
                // Hidden markers still need a color; the glyph suppression that
                // makes them zero-width lives in the layout manager delegate.
                storage.addAttribute(
                    .foregroundColor, value: palette.markerDim.nsColor, range: spanRange
                )
                continue
            }
            let level = headingLevels[lineStart(of: span.range.location)] ?? span.level
            storage.addAttributes(
                builder.attributes(for: span, revealed: revealed, headingLevel: level),
                range: spanRange
            )
        }

        // Kerning on the outer characters of each tag gives the pill padding
        // without inserting characters the user would have to type through.
        for tag in result.tagRanges {
            let tagRange = NSIntersectionRange(tag, clamped)
            guard tagRange.length > 0 else { continue }
            if NSLocationInRange(tag.location, clamped) {
                storage.addAttribute(
                    .kern,
                    value: MarkdownAttributeBuilder.tagKerning,
                    range: NSRange(location: tag.location, length: 1)
                )
            }
            let last = NSMaxRange(tag) - 1
            if NSLocationInRange(last, clamped) {
                storage.addAttribute(
                    .kern,
                    value: MarkdownAttributeBuilder.tagKerning,
                    range: NSRange(location: last, length: 1)
                )
            }
        }

        storage.endEditing()

        mergeExported(tags: result.tagRanges, tasks: result.taskBracketRanges, in: clamped)
        restyledRanges.append(clamped)
        applyFocusDim()
        textView.setNeedsDisplay(textView.visibleRect)
    }

    /// Keeps the exported tag and task ranges consistent when only part of the
    /// document was rescanned.
    private func mergeExported(tags: [NSRange], tasks: [NSRange], in range: NSRange) {
        tagRanges = tagRanges.filter { NSIntersectionRange($0, range).length == 0 } + tags
        tagRanges.sort { $0.location < $1.location }
        taskBracketRanges = taskBracketRanges.filter {
            NSIntersectionRange($0, range).length == 0
        } + tasks
        taskBracketRanges.sort { $0.location < $1.location }
    }

    // MARK: - Selection

    /// Re-reveals markers around the caret and refreshes the focus dim.
    ///
    /// Only the previously and newly revealed blocks are restyled, so moving
    /// the caret within a line does no work at all.
    func selectionDidChange(to selection: NSRange) {
        guard let textView else { return }
        let text = textView.string as NSString
        let block = blockRange(in: text, touching: selection)
        guard profile.markerVisibility != .always || focusModeEnabled else { return }

        if revealedRange == block {
            applyFocusDim()
            return
        }
        let previous = revealedRange
        revealedRange = block

        var regions: [NSRange] = [block]
        if let previous, previous != block { regions.append(previous) }
        for region in regions {
            apply(
                scanResult(for: region, fenceState: fenceState(at: region.location, in: text)),
                to: region
            )
        }
        if regions.isEmpty { applyFocusDim() }
    }

    /// Typing attributes for the caret, so continuing a bold run stays bold and
    /// typing on a heading line keeps the heading metrics.
    func typingAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        guard let textView else { return builder.baseAttributes() }
        let text = textView.string as NSString
        guard text.length > 0 else { return builder.baseAttributes() }

        let clamped = min(max(location, 0), text.length)
        let block = blockRange(in: text, touching: NSRange(location: clamped, length: 0))
        let result = scanResult(for: block, fenceState: fenceState(at: block.location, in: text))
        let builder = self.builder

        var attributes = builder.baseAttributes()

        if let blockStyle = result.blocks.first(where: {
            NSLocationInRange(clamped, $0.lineRange) || NSMaxRange($0.lineRange) == clamped
        }) {
            attributes[.paragraphStyle] = builder.paragraphStyle(for: blockStyle)
            if case .heading(let level) = blockStyle.kind {
                let size = profile.headingSize(level: level)
                attributes[.font] = MarkdownAttributeBuilder.applying(
                    weight: profile.roleStyle(for: .heading).weight,
                    italic: false,
                    to: MarkdownAttributeBuilder.font(named: profile.fontFamily, size: size),
                    size: size
                )
            }
        }

        // Innermost inline span *strictly* containing the caret, so typing at a
        // closing delimiter does not inherit the run being closed.
        let containing = result.spans
            .filter { span in
                span.range.location < clamped && clamped < NSMaxRange(span.range)
                    && !builder.isMarker(span.role)
            }
            .min { $0.range.length < $1.range.length }
        if let containing {
            let inline = builder.attributes(
                for: containing, revealed: true, headingLevel: containing.level
            )
            attributes.merge(inline) { _, new in new }
        }
        return attributes
    }

    // MARK: - Focus mode

    /// Dims everything except the caret's paragraph.
    ///
    /// This is the one thing Markdown uses temporary attributes for, and it has
    /// to be: focus flips on every caret move, and a temporary attribute cannot
    /// affect layout, so it is guaranteed not to reflow the document.
    func applyFocusDim() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let text = textView.string as NSString
        let window = union(visibleRange(padding: 4_000), NSRange(location: 0, length: 0))
        let clamped = NSIntersectionRange(window, NSRange(location: 0, length: text.length))
        guard clamped.length > 0 else { return }

        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: clamped)
        guard focusModeEnabled else { return }

        let focus = blockRange(in: text, touching: textView.selectedRange())
        let dim = palette.focusDim.nsColor
        if clamped.location < focus.location {
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: dim,
                forCharacterRange: NSRange(
                    location: clamped.location,
                    length: min(focus.location, NSMaxRange(clamped)) - clamped.location
                )
            )
        }
        let tailStart = max(NSMaxRange(focus), clamped.location)
        if tailStart < NSMaxRange(clamped) {
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: dim,
                forCharacterRange: NSRange(
                    location: tailStart,
                    length: NSMaxRange(clamped) - tailStart
                )
            )
        }
    }

    // MARK: - Geometry helpers

    /// The blank-line-delimited block containing `range`.
    private func blockRange(in text: NSString, touching range: NSRange) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let clampedLocation = min(max(range.location, 0), max(0, text.length - 1))
        var start = text.lineRange(for: NSRange(location: clampedLocation, length: 0)).location
        let endLocation = min(max(NSMaxRange(range), clampedLocation), text.length)
        var end = NSMaxRange(
            text.lineRange(for: NSRange(location: min(endLocation, max(0, text.length - 1)), length: 0))
        )

        while start > 0 {
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlank(text, previous) { break }
            start = previous.location
        }
        while end < text.length {
            let next = text.lineRange(for: NSRange(location: end, length: 0))
            if isBlank(text, next) { break }
            end = NSMaxRange(next)
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    private func isBlank(_ text: NSString, _ range: NSRange) -> Bool {
        let trimmed = text.substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
    }

    private func lineStart(of location: Int) -> Int {
        guard let textView else { return location }
        let text = textView.string as NSString
        guard text.length > 0 else { return 0 }
        let clamped = min(max(location, 0), max(0, text.length - 1))
        return text.lineRange(for: NSRange(location: clamped, length: 0)).location
    }

    private func fenceState(at location: Int, in text: NSString) -> Bool {
        MarkdownStyleScanner.fenceState(of: text, atLineStartingAt: location)
    }

    private func visibleRange(padding: Int) -> NSRange {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return NSRange(location: 0, length: 0) }

        let length = (textView.string as NSString).length
        guard length > 0 else { return NSRange(location: 0, length: 0) }

        // In a test window with no scroll view the visible rect can be empty;
        // fall back to the whole document so styling still happens.
        let rect = textView.enclosingScrollView?.contentView.bounds ?? textView.bounds
        guard rect.width > 0, rect.height > 0 else {
            return NSRange(location: 0, length: length)
        }
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange, actualGlyphRange: nil
        )
        let start = max(0, characterRange.location - padding)
        let end = min(length, NSMaxRange(characterRange) + padding)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func union(_ a: NSRange, _ b: NSRange) -> NSRange {
        guard a.length > 0 else { return b }
        guard b.length > 0 else { return a }
        let start = min(a.location, b.location)
        let end = max(NSMaxRange(a), NSMaxRange(b))
        return NSRange(location: start, length: end - start)
    }
}
