import AppKit

/// NSTextView configured for plain-text editing, with the editor commands,
/// bracket/quote pairing, and Markdown helpers Ashtyn MD adds on top.
/// Syntax appearance and helpers never change file contents on their own —
/// every mutation here is an explicit, undoable user edit.
final class PlainTextView: NSTextView {
    /// Language facts used by comment toggling and pairing.
    var languageDefinition: LanguageDefinition?
    /// Active per-language profile (tab width, spaces vs tabs, …).
    var profile: EditorProfile = .defaultProfile(for: .plainText)
    /// Invoked by the Toggle Line Wrap menu command; owned by the coordinator
    /// because wrapping is configured on the enclosing scroll view.
    var wrapToggleHandler: (() -> Void)?
    /// Writes pasted/dropped image data to the Assets folder and returns the
    /// relative Markdown path to insert, or nil to decline.
    var imageInsertionHandler: ((Data, String) -> String?)?
    /// Streamed AI suggestion shown at the caret; never part of the document.
    var ghostText: String? {
        didSet { needsDisplay = true }
    }
    /// Returns true when a visible ghost suggestion was accepted.
    var ghostAcceptHandler: (() -> Bool)?
    var ghostDismissHandler: (() -> Void)?
    /// Manual AI completion (⌃⌥Space).
    var aiCompletionRequestHandler: (() -> Void)?

    @objc func requestAICompletion(_ sender: Any?) {
        aiCompletionRequestHandler?()
    }

    /// Undoable programmatic edit used by preview interactions.
    @discardableResult
    func applyExternalEdit(range: NSRange, replacement: String) -> Bool {
        guard NSMaxRange(range) <= content.length,
              shouldChangeText(in: range, replacementString: replacement) else { return false }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        return true
    }

    private var content: NSString { string as NSString }

    private var indentUnit: String {
        profile.usesTabs ? "\t" : String(repeating: " ", count: max(1, profile.tabWidth))
    }

    // MARK: - Paste

    /// Pasting requests the pasteboard's plain string, preserves its
    /// characters and line breaks, and normalizes internal newlines to `\n`.
    /// Never reindents or reformats.
    override func paste(_ sender: Any?) {
        pasteNormalizedPlainText()
    }

    override func pasteAsPlainText(_ sender: Any?) {
        pasteNormalizedPlainText()
    }

    private func pasteNormalizedPlainText() {
        let pasteboard = NSPasteboard.general
        if insertImageFromPasteboard(pasteboard) { return }
        guard let raw = pasteboard.string(forType: .string) else {
            NSSound.beep()
            return
        }
        let normalized = LineEnding.normalizeToLF(raw)
        insertText(normalized, replacementRange: selectedRange())
    }

    /// Handles image data on the pasteboard (Markdown only). Returns true
    /// when an image link was inserted.
    private func insertImageFromPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard languageDefinition?.id == .markdown,
              let handler = imageInsertionHandler else { return false }

        // A copied image file from Finder.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let imageURL = urls.first(where: { Self.imageExtensions.contains($0.pathExtension.lowercased()) }),
           let data = try? Data(contentsOf: imageURL) {
            return insertImageLink(handler(data, imageURL.pathExtension.lowercased()))
        }
        // Raw image data (screenshot, copied bitmap).
        if let data = pasteboard.data(forType: .png) {
            return insertImageLink(handler(data, "png"))
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return insertImageLink(handler(png, "png"))
        }
        return false
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp",
    ]

    private func insertImageLink(_ relativePath: String?) -> Bool {
        guard let relativePath else { return false }
        let name = (relativePath as NSString).lastPathComponent
        insertText("![\(name)](\(relativePath))", replacementRange: selectedRange())
        return true
    }

    // MARK: - Image drops

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if languageDefinition?.id == .markdown,
           imageInsertionHandler != nil,
           let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let images = urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            if !images.isEmpty {
                for imageURL in images {
                    guard let data = try? Data(contentsOf: imageURL),
                          let handler = imageInsertionHandler else { continue }
                    _ = insertImageLink(handler(data, imageURL.pathExtension.lowercased()))
                }
                return true
            }
        }
        return super.performDragOperation(sender)
    }

    // MARK: - Current line highlight

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0,
              window?.firstResponder === self,
              let layoutManager, let textContainer else { return }

        let caret = min(selectedRange().location, content.length)
        let lineRange = content.lineRange(for: NSRange(location: caret, length: 0))

        var fragmentRect: NSRect
        if lineRange.location >= content.length {
            fragmentRect = layoutManager.extraLineFragmentRect
        } else {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        }
        guard fragmentRect.height > 0 else { return }

        var highlightRect = fragmentRect
        highlightRect.origin.x = 0
        highlightRect.size.width = bounds.width
        highlightRect.origin.y += textContainerInset.height
        guard highlightRect.intersects(rect) else { return }

        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.14).setFill()
        highlightRect.fill()
    }

    // MARK: - Bracket and quote pairing

    private static let pairMap: [String: String] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`",
    ]
    private static let closingDelimiters: Set<String> = [")", "]", "}", "\"", "'", "`"]

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let typed = insertString as? String else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let selection = selectedRange()

        // Skip over a closing delimiter that's already there.
        if Self.closingDelimiters.contains(typed),
           selection.length == 0,
           character(at: selection.location) == typed,
           !(Self.pairMap[typed] != nil && shouldAutoPairQuote(typed, at: selection.location)) {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }

        if let closing = Self.pairMap[typed] {
            let isQuote = typed == closing
            if selection.length > 0 {
                // Wrap the selection in the pair.
                let wrapped = typed + content.substring(with: selection) + closing
                insertUndoably(wrapped, in: selection,
                               select: NSRange(location: selection.location + 1, length: selection.length))
                return
            }
            let shouldPair = isQuote
                ? shouldAutoPairQuote(typed, at: selection.location)
                : shouldAutoPairBracket(at: selection.location)
            if shouldPair {
                insertUndoably(typed + closing, in: selection,
                               select: NSRange(location: selection.location + 1, length: 0))
                return
            }
        }

        super.insertText(insertString, replacementRange: replacementRange)
    }

    /// Delete an empty pair as a unit.
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, selection.location > 0,
           let previous = character(at: selection.location - 1),
           let closing = Self.pairMap[previous],
           character(at: selection.location) == closing {
            insertUndoably("", in: NSRange(location: selection.location - 1, length: 2), select: nil)
            return
        }
        super.deleteBackward(sender)
    }

    private func character(at location: Int) -> String? {
        guard location >= 0, location < content.length else { return nil }
        return content.substring(with: NSRange(location: location, length: 1))
    }

    private func shouldAutoPairBracket(at location: Int) -> Bool {
        guard let next = character(at: location) else { return true }
        // Pair before whitespace, closers, or end of line — not before text.
        return next.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            || Self.closingDelimiters.contains(next)
    }

    private func shouldAutoPairQuote(_ quote: String, at location: Int) -> Bool {
        // Apostrophes in prose (Markdown/plain text) must never pair.
        if quote == "'", languageDefinition?.id == .markdown || languageDefinition?.id == .plainText {
            return false
        }
        if let previous = character(at: location - 1),
           previous.rangeOfCharacter(from: .alphanumerics) != nil || previous == quote {
            return false
        }
        guard let next = character(at: location) else { return true }
        return next.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            || Self.closingDelimiters.contains(next)
    }

    // MARK: - Newline behavior

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, !hasMarkedText() else {
            super.insertNewline(sender)
            return
        }
        let caret = selection.location
        let lineRange = content.lineRange(for: NSRange(location: min(caret, content.length), length: 0))
        let lineEnd = content.lineContent(in: lineRange)
        let line = lineEnd.line
        let beforeCaret = String(line.prefix(max(0, caret - lineRange.location)))
        let leadingWhitespace = String(line.prefix(while: { $0 == " " || $0 == "\t" }))

        // Markdown list continuation.
        if languageDefinition?.id == .markdown,
           caret >= lineRange.location + (line as NSString).length - (lineEnd.hasNewline ? 0 : 0),
           let continuation = MarkdownListHelper.continuation(forLine: line) {
            switch continuation {
            case .terminate(let markerRange):
                // Empty item: pressing return removes the marker and ends the list.
                let absolute = NSRange(location: lineRange.location + markerRange.location,
                                       length: markerRange.length)
                insertUndoably("", in: absolute, select: nil)
                return
            case .continueWith(let marker):
                super.insertNewline(sender)
                insertText(marker, replacementRange: selectedRange())
                return
            }
        }

        // Fenced-code helper: opening a fence auto-closes it.
        if languageDefinition?.id == .markdown,
           MarkdownListHelper.lineOpensUnclosedFence(beforeCaret, in: string, lineStart: lineRange.location) {
            super.insertNewline(sender)
            let position = selectedRange()
            insertText("\n```", replacementRange: position)
            setSelectedRange(position)
            return
        }

        // Brace expansion: newline between { and } opens an indented body.
        if let previous = character(at: caret - 1), previous == "{",
           let next = character(at: caret), next == "}" {
            let body = "\n\(leadingWhitespace)\(indentUnit)\n\(leadingWhitespace)"
            insertUndoably(body, in: selection,
                           select: NSRange(
                            location: caret + 1 + (leadingWhitespace as NSString).length + (indentUnit as NSString).length,
                            length: 0
                           ))
            return
        }

        // Plain auto-indent: carry the leading whitespace forward.
        super.insertNewline(sender)
        if !leadingWhitespace.isEmpty {
            insertText(leadingWhitespace, replacementRange: selectedRange())
        }
    }

    // MARK: - Tab behavior

    override func insertTab(_ sender: Any?) {
        // Tab accepts visible AI ghost text before anything else.
        if ghostText != nil, ghostAcceptHandler?() == true { return }
        let selection = selectedRange()
        let selectedLines = content.lineRange(for: selection)
        let spansMultipleLines = content.substring(with: NSRange(
            location: selectedLines.location,
            length: max(0, selection.location + selection.length - selectedLines.location - (selection.length > 0 ? 1 : 0))
        )).contains("\n")
        if selection.length > 0 && spansMultipleLines {
            indentSelection(sender)
            return
        }
        insertText(indentUnit, replacementRange: selection)
    }

    override func insertBacktab(_ sender: Any?) {
        outdentSelection(sender)
    }

    /// Escape dismisses ghost text before the native cancel behavior.
    override func cancelOperation(_ sender: Any?) {
        if ghostText != nil {
            ghostDismissHandler?()
            return
        }
        complete(nil)
    }

    // MARK: - Ghost text drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawGhostTextIfNeeded()
    }

    private func drawGhostTextIfNeeded() {
        guard let ghostText, !ghostText.isEmpty else { return }
        let caret = selectedRange()
        guard caret.length == 0 else { return }

        // Caret rect in view coordinates via the screen-space first rect.
        let screenRect = firstRect(forCharacterRange: caret, actualRange: nil)
        guard screenRect.width >= 0, let window else { return }
        let windowRect = window.convertFromScreen(screenRect)
        var origin = convert(windowRect, from: nil).origin

        let ghostFont = font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ghostFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let lineHeight = windowRect.height > 0
            ? convert(windowRect, from: nil).height
            : ghostFont.boundingRectForFont.height

        // First line continues at the caret; a few more lines draw below.
        var lines = ghostText.components(separatedBy: "\n")
        let maximumLines = 4
        var truncated = false
        if lines.count > maximumLines {
            lines = Array(lines.prefix(maximumLines))
            truncated = true
        }
        for (index, line) in lines.enumerated() {
            var display = line
            if index == lines.count - 1 && truncated { display += " …" }
            let point = NSPoint(
                x: index == 0 ? origin.x : textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                y: origin.y + CGFloat(index) * lineHeight
            )
            (display as NSString).draw(at: point, withAttributes: attributes)
        }
        _ = origin
    }

    // MARK: - Line commands

    /// Full line range of the selection, including trailing newline when present.
    private func selectedLinesRange() -> NSRange {
        content.lineRange(for: selectedRange())
    }

    @objc func duplicateLineOrSelection(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0 {
            let text = content.substring(with: selection)
            insertUndoably(text + text, in: selection,
                           select: NSRange(location: selection.location + (text as NSString).length,
                                           length: (text as NSString).length))
            return
        }
        let lines = selectedLinesRange()
        var text = content.substring(with: lines)
        var insertion = text
        if !text.hasSuffix("\n") {
            // Last line without trailing newline duplicates below itself.
            insertion = text + "\n" + text
        } else {
            insertion = text + text
        }
        let caretOffset = selection.location - lines.location
        let duplicatedStart = lines.location + (insertion as NSString).length - (text.hasSuffix("\n") ? (text as NSString).length : (text as NSString).length)
        insertUndoably(insertion, in: lines,
                       select: NSRange(location: duplicatedStart + caretOffset, length: 0))
    }

    @objc func deleteCurrentLines(_ sender: Any?) {
        var lines = selectedLinesRange()
        if NSMaxRange(lines) == content.length, lines.location > 0,
           !content.substring(with: lines).hasSuffix("\n") {
            // Deleting the last line also removes the newline before it.
            lines = NSRange(location: lines.location - 1, length: lines.length + 1)
        }
        let caretColumn = selectedRange().location - content.lineRange(for: selectedRange()).location
        insertUndoably("", in: lines, select: nil)
        // Keep the caret near where it was, clamped to the replacement line.
        let newContent = string as NSString
        let target = min(lines.location, newContent.length)
        let newLine = newContent.lineRange(for: NSRange(location: target, length: 0))
        let column = min(caretColumn, max(0, newLine.length == 0 ? 0 : newLine.length - (NSMaxRange(newLine) == newContent.length ? 0 : 1)))
        setSelectedRange(NSRange(location: newLine.location + max(0, column), length: 0))
    }

    @objc func moveLinesUp(_ sender: Any?) {
        let lines = selectedLinesRange()
        guard lines.location > 0 else { return }
        let previousLine = content.lineRange(for: NSRange(location: lines.location - 1, length: 0))

        var moving = content.substring(with: lines)
        var above = content.substring(with: previousLine)
        let hadTrailingNewline = moving.hasSuffix("\n")
        if !hadTrailingNewline {
            // Moving the last line up: it gains a newline, the line above loses its own.
            moving += "\n"
            above = String(above.dropLast(above.hasSuffix("\n") ? 1 : 0))
        }
        let combined = NSRange(location: previousLine.location, length: previousLine.length + lines.length)
        let selectionOffset = selectedRange().location - lines.location
        let selectionLength = selectedRange().length
        insertUndoably(moving + above, in: combined,
                       select: NSRange(location: previousLine.location + selectionOffset,
                                       length: selectionLength))
    }

    @objc func moveLinesDown(_ sender: Any?) {
        let lines = selectedLinesRange()
        guard NSMaxRange(lines) < content.length else { return }
        let nextLine = content.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0))

        var moving = content.substring(with: lines)
        var below = content.substring(with: nextLine)
        if !below.hasSuffix("\n") {
            // Moving above the (newline-less) last line: swap the newline over.
            below += "\n"
            moving = String(moving.dropLast(moving.hasSuffix("\n") ? 1 : 0))
        }
        let combined = NSRange(location: lines.location, length: lines.length + nextLine.length)
        let selectionOffset = selectedRange().location - lines.location
        let selectionLength = selectedRange().length
        insertUndoably(below + moving, in: combined,
                       select: NSRange(location: lines.location + (below as NSString).length + selectionOffset,
                                       length: selectionLength))
    }

    @objc func indentSelection(_ sender: Any?) {
        transformSelectedLines { line in
            line.isEmpty ? line : indentUnit + line
        }
    }

    @objc func outdentSelection(_ sender: Any?) {
        let width = max(1, profile.tabWidth)
        transformSelectedLines { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            var removed = 0
            var result = line
            while removed < width, result.hasPrefix(" ") {
                result = String(result.dropFirst())
                removed += 1
            }
            return result
        }
    }

    @objc func toggleComment(_ sender: Any?) {
        guard let definition = languageDefinition else { return }
        if let prefix = definition.lineCommentPrefix {
            toggleLineComment(prefix: prefix)
        } else if let block = definition.blockComment {
            toggleBlockComment(start: block.start, end: block.end)
        }
    }

    private func toggleLineComment(prefix: String) {
        let commented = linesInSelection().allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix(prefix)
        }
        transformSelectedLines { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return line }
            if commented {
                guard let markerRange = line.range(of: prefix) else { return line }
                var result = line
                var removal = markerRange
                // Also remove one space after the marker, if present.
                if line[markerRange.upperBound...].hasPrefix(" ") {
                    removal = markerRange.lowerBound..<line.index(after: markerRange.upperBound)
                }
                result.removeSubrange(removal)
                return result
            } else {
                let insertAt = line.firstIndex(where: { $0 != " " && $0 != "\t" }) ?? line.startIndex
                var result = line
                result.insert(contentsOf: prefix + " ", at: insertAt)
                return result
            }
        }
    }

    private func toggleBlockComment(start: String, end: String) {
        var selection = selectedRange()
        if selection.length == 0 {
            selection = content.lineRange(for: selection)
            if content.substring(with: selection).hasSuffix("\n") {
                selection.length -= 1
            }
        }
        let text = content.substring(with: selection)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(start) && trimmed.hasSuffix(end) {
            var unwrapped = text
            if let startRange = unwrapped.range(of: start) {
                var removal = startRange
                if unwrapped[startRange.upperBound...].hasPrefix(" ") {
                    removal = startRange.lowerBound..<unwrapped.index(after: startRange.upperBound)
                }
                unwrapped.removeSubrange(removal)
            }
            if let endRange = unwrapped.range(of: end, options: .backwards) {
                var removal = endRange
                if unwrapped[..<endRange.lowerBound].hasSuffix(" ") {
                    removal = unwrapped.index(before: endRange.lowerBound)..<endRange.upperBound
                }
                unwrapped.removeSubrange(removal)
            }
            insertUndoably(unwrapped, in: selection,
                           select: NSRange(location: selection.location, length: (unwrapped as NSString).length))
        } else {
            let wrapped = "\(start) \(text) \(end)"
            insertUndoably(wrapped, in: selection,
                           select: NSRange(location: selection.location, length: (wrapped as NSString).length))
        }
    }

    @objc func toggleLineWrap(_ sender: Any?) {
        wrapToggleHandler?()
    }

    // MARK: - Go to line

    @objc func goToLine(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "Line number"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let line = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
                  line > 0 else { return }
            self?.jump(toLine: line)
        }
    }

    func jump(toLine target: Int) {
        var lineNumber = 1
        var index = 0
        while lineNumber < target && index < content.length {
            index = NSMaxRange(content.lineRange(for: NSRange(location: index, length: 0)))
            lineNumber += 1
        }
        let range = NSRange(location: min(index, content.length), length: 0)
        setSelectedRange(range)
        scrollRangeToVisible(range)
    }

    // MARK: - Editing plumbing

    /// Replaces a range through the undo-aware editing pipeline and restores
    /// a sensible selection.
    private func insertUndoably(_ text: String, in range: NSRange, select: NSRange?) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let select {
            let limit = (string as NSString).length
            let clamped = NSRange(
                location: min(select.location, limit),
                length: min(select.length, max(0, limit - min(select.location, limit)))
            )
            setSelectedRange(clamped)
        }
        typingAttributes = defaultTypingAttributes()
    }

    private func defaultTypingAttributes() -> [NSAttributedString.Key: Any] {
        var attributes = typingAttributes
        attributes[.foregroundColor] = NSColor.textColor
        return attributes
    }

    private func linesInSelection() -> [String] {
        let lines = selectedLinesRange()
        var result = content.substring(with: lines)
        if result.hasSuffix("\n") { result.removeLast() }
        return result.components(separatedBy: "\n")
    }

    /// Applies a per-line transform to every selected line as one undo group,
    /// preserving the selection over the transformed block.
    private func transformSelectedLines(_ transform: (String) -> String) {
        let lines = selectedLinesRange()
        var block = content.substring(with: lines)
        let hadTrailingNewline = block.hasSuffix("\n")
        if hadTrailingNewline { block.removeLast() }
        let transformed = block.components(separatedBy: "\n").map(transform).joined(separator: "\n")
        let replacement = transformed + (hadTrailingNewline ? "\n" : "")
        insertUndoably(replacement, in: lines,
                       select: NSRange(location: lines.location, length: (replacement as NSString).length))
    }
}

private extension NSString {
    /// The text of a line range, plus whether it ends with a newline.
    func lineContent(in lineRange: NSRange) -> (line: String, hasNewline: Bool) {
        var text = substring(with: lineRange)
        let hasNewline = text.hasSuffix("\n")
        if hasNewline { text.removeLast() }
        return (text, hasNewline)
    }
}

/// Markdown-specific line helpers, separated for testability.
enum MarkdownListHelper {
    enum Continuation: Equatable {
        /// Continue the list: insert this marker after the newline.
        case continueWith(String)
        /// The item is empty: remove the marker (range within the line) instead.
        case terminate(NSRange)
    }

    /// Decides what pressing return at the end of `line` should do.
    static func continuation(forLine line: String) -> Continuation? {
        let ns = line as NSString
        guard let match = listMarkerRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }

        let indent = ns.substring(with: match.range(at: 1))
        let marker = ns.substring(with: match.range(at: 2))
        let rest = ns.substring(from: NSMaxRange(match.range(at: 2)))

        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            return .terminate(NSRange(location: 0, length: ns.length))
        }

        // Ordered lists increment; bullets and tasks repeat (tasks unchecked).
        if let numberMatch = orderedRegex.firstMatch(
            in: marker, range: NSRange(location: 0, length: (marker as NSString).length)
        ) {
            let numberText = (marker as NSString).substring(with: numberMatch.range(at: 1))
            let separator = (marker as NSString).substring(with: numberMatch.range(at: 2))
            let next = (Int(numberText) ?? 0) + 1
            return .continueWith("\(indent)\(next)\(separator) ")
        }
        if marker.contains("[") {
            let bullet = marker.first.map(String.init) ?? "-"
            return .continueWith("\(indent)\(bullet) [ ] ")
        }
        return .continueWith("\(indent)\(marker)")
    }

    /// True when `linePrefix` opens a code fence that has no closing fence
    /// later in the document.
    static func lineOpensUnclosedFence(_ linePrefix: String, in fullText: String, lineStart: Int) -> Bool {
        let trimmed = linePrefix.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return false }
        // Count fence lines in the remainder of the document.
        let ns = fullText as NSString
        let remainderStart = min(lineStart + (linePrefix as NSString).length, ns.length)
        let remainder = ns.substring(from: remainderStart)
        let closingCount = remainder
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .count
        return closingCount % 2 == 0
    }

    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: #"^(\s*)([-*+] \[[ xX]\] |[-*+] |\d+[.)] )(.*)$"#
    )
    private static let orderedRegex = try! NSRegularExpression(
        pattern: #"^(\d+)([.)])"#
    )
}
