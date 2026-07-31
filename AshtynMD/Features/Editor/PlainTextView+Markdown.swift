import AppKit

/// Bear-style formatting commands.
///
/// Each is a thin adapter over a pure transform in `MarkdownTransforms`, so the
/// semantics (what happens on an empty selection, a word, a range, several
/// lines, or an already-applied run) are tested without a text view and this
/// file stays mechanical.
extension PlainTextView {
    // MARK: - Inline

    // Deliberately not named toggleBoldface:/toggleItalics: — those are
    // standard NSResponder selectors that NSTextView implements as no-ops when
    // isRichText is false, so a custom name is required to get called at all.
    @objc func toggleMarkdownBold(_ sender: Any?) {
        applyMarkdownEdit(inlineToggle(.bold))
    }

    @objc func toggleMarkdownItalic(_ sender: Any?) {
        applyMarkdownEdit(inlineToggle(.italic))
    }

    @objc func toggleMarkdownInlineCode(_ sender: Any?) {
        applyMarkdownEdit(inlineToggle(.inlineCode))
    }

    @objc func toggleMarkdownStrikethrough(_ sender: Any?) {
        applyMarkdownEdit(inlineToggle(.strikethrough))
    }

    @objc func insertMarkdownLink(_ sender: Any?) {
        let clipboard = NSPasteboard.general.string(forType: .string)
        applyMarkdownEdit(
            MarkdownInlineTransform.link(
                in: markdownContent,
                selection: selectedRange(),
                clipboardURL: clipboard
            )
        )
    }

    private func inlineToggle(_ style: MarkdownInlineStyle) -> TextEdit? {
        MarkdownInlineTransform.toggle(style, in: markdownContent, selection: selectedRange())
    }

    // MARK: - Headings

    // Six explicit selectors rather than one taking a level: NSApp.sendAction
    // carries no sender or tag through the responder chain.
    @objc func setMarkdownHeading1(_ sender: Any?) { applyHeading(1) }
    @objc func setMarkdownHeading2(_ sender: Any?) { applyHeading(2) }
    @objc func setMarkdownHeading3(_ sender: Any?) { applyHeading(3) }
    @objc func setMarkdownHeading4(_ sender: Any?) { applyHeading(4) }
    @objc func setMarkdownHeading5(_ sender: Any?) { applyHeading(5) }
    @objc func setMarkdownHeading6(_ sender: Any?) { applyHeading(6) }

    @objc func clearMarkdownBlockStyle(_ sender: Any?) {
        applyMarkdownEdit(
            MarkdownBlockTransform.clearBlockStyle(in: markdownContent, selection: selectedRange())
        )
    }

    private func applyHeading(_ level: Int) {
        applyMarkdownEdit(
            MarkdownBlockTransform.setHeading(
                level: level, in: markdownContent, selection: selectedRange()
            )
        )
    }

    // MARK: - Blocks

    @objc func toggleMarkdownQuote(_ sender: Any?) {
        applyMarkdownEdit(
            MarkdownBlockTransform.toggleQuote(in: markdownContent, selection: selectedRange())
        )
    }

    @objc func toggleMarkdownBulletList(_ sender: Any?) {
        applyMarkdownEdit(
            MarkdownBlockTransform.toggleList(
                ordered: false, in: markdownContent, selection: selectedRange()
            )
        )
    }

    @objc func toggleMarkdownNumberedList(_ sender: Any?) {
        applyMarkdownEdit(
            MarkdownBlockTransform.toggleList(
                ordered: true, in: markdownContent, selection: selectedRange()
            )
        )
    }

    @objc func toggleMarkdownTask(_ sender: Any?) {
        applyMarkdownEdit(
            MarkdownBlockTransform.toggleTask(in: markdownContent, selection: selectedRange())
        )
    }

    @objc func insertMarkdownDivider(_ sender: Any?) {
        applyMarkdownEdit(
            MarkdownBlockTransform.divider(in: markdownContent, selection: selectedRange())
        )
    }

    // MARK: - Modes

    @objc func toggleFocusMode(_ sender: Any?) {
        guard isMarkdownDocument else { return NSSound.beep() }
        markdownModeToggleHandler?(.focus)
    }

    @objc func toggleTypewriterMode(_ sender: Any?) {
        guard isMarkdownDocument else { return NSSound.beep() }
        markdownModeToggleHandler?(.typewriter)
    }

    @objc func cycleMarkerVisibility(_ sender: Any?) {
        guard isMarkdownDocument else { return NSSound.beep() }
        markdownModeToggleHandler?(.markerVisibility)
    }

    // MARK: - Shared plumbing

    var isMarkdownDocument: Bool {
        languageDefinition?.id == .markdown
    }

    private var markdownContent: NSString {
        string as NSString
    }

    /// Applies a transform, or beeps.
    ///
    /// The language guard is here as well as on the menu item because
    /// `NSApp.sendAction` walks the responder chain and can reach a code editor
    /// in another window.
    private func applyMarkdownEdit(_ edit: TextEdit?) {
        guard isMarkdownDocument else { return NSSound.beep() }
        guard let edit else { return NSSound.beep() }
        guard NSMaxRange(edit.range) <= markdownContent.length else { return NSSound.beep() }
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()

        let limit = markdownContent.length
        let location = min(edit.selection.location, limit)
        setSelectedRange(
            NSRange(location: location, length: min(edit.selection.length, limit - location))
        )
    }
}

/// Editor modes toggled from the View menu and owned by the coordinator, which
/// holds the profile and the scroll view they need.
enum MarkdownEditorMode: Sendable {
    case focus
    case typewriter
    case markerVisibility
}
