import AppKit
import SwiftUI

/// SwiftUI wrapper around PlainTextView. The session is the source of truth;
/// edits flow session-ward through the delegate, and external replacements
/// (reload, recovery restore) flow view-ward in updateNSView.
struct EditorTextView: NSViewRepresentable {
    let session: DocumentSession
    let profile: EditorProfile
    let theme: EditorTheme
    /// Writes image data to Assets and returns the relative Markdown path.
    var imageInsertion: ((Data, String) -> String?)?

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = PlainTextView(frame: .zero)
        // Touching layoutManager selects TextKit 1 compatibility mode — the
        // mature layout path the syntax gutter and temporary attributes need.
        _ = textView.layoutManager
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier(AccessibilityID.editor)
        textView.setAccessibilityLabel("Document editor")

        scrollView.documentView = textView
        context.coordinator.textView = textView
        textView.textStorage?.delegate = context.coordinator

        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        textView.postsFrameChangedNotifications = true

        textView.wrapToggleHandler = { [weak coordinator = context.coordinator, weak scrollView] in
            guard let coordinator, let scrollView else { return }
            coordinator.toggleWrap(in: scrollView)
        }

        textView.imageInsertionHandler = imageInsertion
        context.coordinator.configureAI(for: textView)
        context.coordinator.registerSourceEditHandler()
        context.coordinator.applyCapabilities(to: textView)
        context.coordinator.applyText(session.text)
        context.coordinator.applyProfile(profile, theme: theme, for: session.languageID, in: scrollView)
        context.coordinator.observeScrolling(of: scrollView)
        context.coordinator.restoreViewState(in: scrollView)
        DispatchQueue.main.async { [weak textView] in
            guard let textView, textView.isEditable else { return }
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.session !== session {
            coordinator.session = session
            coordinator.registerSourceEditHandler()
        }
        coordinator.textView?.imageInsertionHandler = imageInsertion
        guard let textView = coordinator.textView else { return }
        coordinator.applyCapabilities(to: textView)

        if coordinator.appliedLanguage != session.languageID
            || coordinator.appliedProfile != profile
            || coordinator.appliedTheme != theme {
            coordinator.applyProfile(profile, theme: theme, for: session.languageID, in: scrollView)
        }
        if textView.string != session.text {
            coordinator.applyText(session.text)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var session: DocumentSession
        weak var textView: PlainTextView?
        var appliedLanguage: LanguageID?
        var appliedProfile: EditorProfile?
        var appliedTheme: EditorTheme?
        private var isApplyingProgrammaticChange = false

        private let highlighter = SyntaxHighlighter()
        private var highlightTask: Task<Void, Never>?
        private var editSequence: UInt64 = 0
        /// Range of the most recent character edit, captured from the storage
        /// delegate so textDidChange knows what to restyle.
        private var lastEditedRange: NSRange?
        /// Non-nil only for Markdown documents.
        var markdownStyler: MarkdownStyler?
        var typewriterScroller: TypewriterScroller?
        /// Suppresses view-state persistence while the typewriter scroll runs,
        /// which would otherwise rewrite the stored offset on every keystroke.
        var isPerformingTypewriterScroll = false
        let aiController = AICompletionController()

        init(session: DocumentSession) {
            self.session = session
            #if DEBUG
            if UITestLaunchConfiguration.current.isEnabled {
                aiController.providerFactory = { UITestAIProvider() }
            }
            #endif
        }

        func configureAI(for textView: PlainTextView) {
            aiController.onGhostTextChange = { [weak textView] text in
                textView?.ghostText = text
            }
            textView.ghostAcceptHandler = { [weak self] in
                guard let self, let text = self.aiController.acceptGhostText(),
                      let textView = self.textView else { return false }
                // Acceptance is one ordinary undoable insertion.
                textView.insertText(text, replacementRange: textView.selectedRange())
                return true
            }
            textView.ghostDismissHandler = { [weak self] in
                self?.aiController.dismissGhostText()
            }
            textView.aiCompletionRequestHandler = { [weak self] in
                guard let self else { return }
                self.aiController.requestManually { [weak self] in
                    self?.makeAIRequest(trigger: .manual)
                }
            }
        }

        func applyCapabilities(to textView: PlainTextView) {
            textView.isEditable = session.capabilities.isEditable
            textView.isSelectable = true
            if !session.capabilities.allowsAICompletion {
                aiController.cancelAll()
            }
        }

        private func makeAIRequest(trigger: AICompletionRequest.Trigger) -> AICompletionRequest? {
            guard session.capabilities.allowsAICompletion else {
                AICompletionStatus.shared.lastError =
                    "AI completion is unavailable in large-file mode."
                return nil
            }
            guard let textView,
                  textView.selectedRange().length == 0,
                  !textView.hasMarkedText() else { return nil }
            return CompletionContext.request(
                text: textView.string,
                caretLocation: textView.selectedRange().location,
                language: appliedLanguage ?? .plainText,
                fileName: session.displayName,
                trigger: trigger
            )
        }

        /// Lets the session route programmatic edits (task toggles) through
        /// the editor's undo stack.
        func registerSourceEditHandler() {
            session.sourceEditHandler = { [weak self] range, replacement in
                guard let textView = self?.textView else { return false }
                return textView.applyExternalEdit(range: range, replacement: replacement)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticChange, let textView else { return }
            session.updateText(textView.string)
            // Restyle here rather than from didProcessEditing: this fires in
            // the same runloop turn once processing has finished, so writing
            // attributes cannot re-enter the storage mid-edit.
            if let markdownStyler {
                markdownStyler.restyle(afterEditIn: lastEditedRange ?? textView.selectedRange())
            }
            // Any edit cancels a stale AI request; automatic completion
            // requires an empty selection and finished input composition.
            aiController.noteEdit(
                isEligible: { [weak textView] in
                    guard let textView else { return false }
                    return textView.selectedRange().length == 0 && !textView.hasMarkedText()
                },
                context: { [weak self] in
                    self?.makeAIRequest(trigger: .automatic)
                }
            )
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingProgrammaticChange, let textView else { return }
            let range = textView.selectedRange()
            session.viewState.cursorLocation = range.location
            session.viewState.selectionLength = range.length
            aiController.noteCursorMovement()
            // Markers reveal on the caret's block, and focus mode follows it.
            markdownStyler?.selectionDidChange(to: range)
            typewriterScroller?.caretDidMove()
            // Current-line highlight follows the caret.
            textView.needsDisplay = true
        }

        /// Offline completion: keywords plus words from the document.
        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let prefix = (textView.string as NSString).substring(with: charRange)
            let local = OfflineCompletion.completions(
                forPrefix: prefix,
                language: appliedLanguage ?? .plainText,
                documentText: textView.string
            )
            index?.pointee = -1
            return local.isEmpty ? words : local
        }

        /// User override for line wrapping, on top of the language profile.
        private var wrapOverride: Bool?

        func toggleWrap(in scrollView: NSScrollView) {
            guard let textView, let profile = appliedProfile else { return }
            let current = wrapOverride ?? profile.wrapsLines
            wrapOverride = !current
            setWrapping(!current, textView: textView, scrollView: scrollView)
        }

        // nonisolated(unsafe): only written on the main actor; read in deinit
        // solely to unregister from NotificationCenter (thread-safe).
        nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

        func observeScrolling(of scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView else { return }
                    if !self.isApplyingProgrammaticChange, !self.isPerformingTypewriterScroll {
                        self.session.viewState.scrollOffset = scrollView.contentView.bounds.origin.y
                    }
                    // Newly revealed lines need colors.
                    self.scheduleHighlight()
                    self.markdownStyler?.restyleVisible()
                }
            }
        }

        // MARK: - Syntax highlighting

        /// NSTextStorageDelegate: captures the edited range so the parser can
        /// reparse incrementally instead of from scratch.
        nonisolated func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            // Attribute-only edits are filtered here, which is what stops the
            // styler's own writes from feeding back into the parser.
            guard editedMask.contains(.editedCharacters) else { return }
            let newText = textStorage.string
            MainActor.assumeIsolated {
                editSequence &+= 1
                lastEditedRange = editedRange
                guard appliedLanguage != .markdown else { return }
                let sequence = editSequence
                let highlighter = highlighter
                Task {
                    await highlighter.applyEdit(
                        newText: newText, editedRange: editedRange, delta: delta, sequence: sequence
                    )
                }
                scheduleHighlight()
            }
        }

        func languageDidChange(_ language: LanguageID) {
            let highlighter = highlighter
            let text = textView?.string ?? ""
            Task {
                await highlighter.setLanguage(language)
                await highlighter.replaceText(text)
            }
            scheduleHighlight()
        }

        func scheduleHighlight() {
            highlightTask?.cancel()
            // Markdown is styled from the text storage by MarkdownStyler; the
            // temporary-attribute path would only fight it.
            guard appliedLanguage != .markdown else { return }
            guard let textView else { return }
            let visible = visibleCharacterRange(of: textView)
            let highlighter = highlighter
            highlightTask = Task { [weak self] in
                let spans = await highlighter.highlights(in: visible)
                guard !Task.isCancelled else { return }
                self?.applyHighlightSpans(spans, in: visible)
            }
        }

        private func visibleCharacterRange(of textView: NSTextView) -> NSRange {
            let fullLength = (textView.string as NSString).length
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else {
                return NSRange(location: 0, length: fullLength)
            }
            let glyphRange = layoutManager.glyphRange(
                forBoundingRect: textView.visibleRect, in: container
            )
            let charRange = layoutManager.characterRange(
                forGlyphRange: glyphRange, actualGlyphRange: nil
            )
            let margin = 2000
            let start = max(0, charRange.location - margin)
            let end = min(fullLength, charRange.location + charRange.length + margin)
            return NSRange(location: start, length: max(0, end - start))
        }

        private func applyHighlightSpans(_ spans: [HighlightSpan], in range: NSRange) {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let fullLength = (textView.string as NSString).length
            let cleared = NSIntersectionRange(range, NSRange(location: 0, length: fullLength))
            guard cleared.length > 0 || spans.isEmpty else { return }

            let isDark = textView.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let palette = effectivePalette(isDark: isDark)

            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: cleared)
            for span in spans {
                let clipped = NSIntersectionRange(
                    span.range, NSRange(location: 0, length: fullLength)
                )
                guard clipped.length > 0, let color = palette.tokens[span.token] else { continue }
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: color.nsColor, forCharacterRange: clipped
                )
            }
        }

        /// Theme palette with per-language profile overrides on top.
        func effectivePalette(isDark: Bool) -> EditorPalette {
            let theme = appliedTheme ?? .system
            var palette = theme.palette(forDarkAppearance: isDark)
            if let overrides = appliedProfile?.tokenColors, !overrides.isEmpty {
                palette.tokens.merge(overrides) { _, override in override }
            }
            return palette
        }

        func restoreViewState(in scrollView: NSScrollView) {
            guard let textView else { return }
            let state = session.viewState
            let length = (textView.string as NSString).length
            let location = min(state.cursorLocation, length)
            let selectionLength = min(state.selectionLength, length - location)
            textView.setSelectedRange(NSRange(location: location, length: selectionLength))
            if state.scrollOffset > 0 {
                // Defer until layout has produced enough document height.
                DispatchQueue.main.async { [weak scrollView] in
                    guard let scrollView else { return }
                    scrollView.contentView.scroll(
                        to: NSPoint(x: 0, y: state.scrollOffset)
                    )
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        /// Replaces the entire content (open, external reload, recovery),
        /// keeping the selection clamped to the new length.
        func applyText(_ text: String) {
            guard let textView else { return }
            isApplyingProgrammaticChange = true
            defer { isApplyingProgrammaticChange = false }

            let previousSelection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            let location = min(previousSelection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            // A full replacement is not an undoable user edit.
            textView.undoManager?.removeAllActions()
            // textDidChange is suppressed above, so the styler has to be told
            // explicitly that the whole buffer changed.
            if let markdownStyler {
                markdownStyler.applyBaseAttributes()
                markdownStyler.restyleAll()
            } else {
                applyCodeBaseAttributes()
            }
        }

        func applyProfile(
            _ profile: EditorProfile,
            theme: EditorTheme,
            for language: LanguageID,
            in scrollView: NSScrollView
        ) {
            guard let textView else { return }
            let languageChanged = appliedLanguage != language
            appliedLanguage = language
            appliedProfile = profile
            appliedTheme = theme
            if languageChanged {
                languageDidChange(language)
            }
            textView.languageDefinition = LanguageDefinition.definition(for: language)
            textView.profile = profile

            let isDark = textView.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let palette = effectivePalette(isDark: isDark)
            textView.palette = palette
            applyChrome(palette, theme: theme, textView: textView, scrollView: scrollView)

            let size = CGFloat(profile.fontSize)
            let font = NSFont(name: profile.fontFamily, size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
            textView.font = font

            setWrapping(wrapOverride ?? profile.wrapsLines, textView: textView, scrollView: scrollView)

            if language == .markdown {
                // Markdown styling lives in the text storage, so the uniform
                // whole-buffer stomp in applyCodeBaseAttributes() would erase
                // it. Hand the buffer to the styler instead.
                let styler = markdownStyler ?? MarkdownStyler(
                    textView: textView, profile: profile, palette: palette
                )
                markdownStyler = styler
                textView.markdownStyler = styler
                styler.profile = profile
                styler.palette = palette
                styler.applyBaseAttributes()
                styler.restyleAll()
                // Line numbers are noise in a prose editor.
                scrollView.rulersVisible = false
            } else {
                markdownStyler = nil
                textView.markdownStyler = nil
                scrollView.rulersVisible = true
                applyCodeBaseAttributes()
                scheduleHighlight()
            }
        }

        /// Background, caret, and selection come from the palette so a theme
        /// can look like something other than the system window.
        private func applyChrome(
            _ palette: EditorPalette,
            theme: EditorTheme,
            textView: PlainTextView,
            scrollView: NSScrollView
        ) {
            textView.drawsBackground = true
            textView.backgroundColor = palette.background.nsColor
            scrollView.drawsBackground = true
            scrollView.backgroundColor = palette.background.nsColor
            textView.insertionPointColor = palette.caret.nsColor
            textView.selectedTextAttributes = [
                .backgroundColor: palette.selection.nsColor
            ]
            if let forced = theme.forcedAppearance {
                // Scrollers and the ruler follow the theme, not the window.
                scrollView.appearance = NSAppearance(
                    named: forced == .dark ? .darkAqua : .aqua
                )
            } else {
                scrollView.appearance = nil
            }
        }

        /// The uniform-font path, for code documents only.
        private func applyCodeBaseAttributes() {
            guard let textView, let profile = appliedProfile else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = profile.lineHeightMultiple

            let size = CGFloat(profile.fontSize)
            let font = NSFont(name: profile.fontFamily, size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
            let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
            paragraph.defaultTabInterval = spaceWidth * CGFloat(profile.tabWidth)
            paragraph.tabStops = []

            textView.defaultParagraphStyle = paragraph
            textView.typingAttributes = [
                .font: font,
                .paragraphStyle: paragraph,
                .foregroundColor: NSColor.textColor,
            ]
            if let storage = textView.textStorage, storage.length > 0 {
                storage.addAttributes(
                    [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.textColor],
                    range: NSRange(location: 0, length: storage.length)
                )
            }
        }

        private func setWrapping(_ wraps: Bool, textView: NSTextView, scrollView: NSScrollView) {
            guard let container = textView.textContainer else { return }
            if wraps {
                container.widthTracksTextView = true
                container.containerSize = NSSize(
                    width: scrollView.contentSize.width, height: .greatestFiniteMagnitude
                )
                textView.maxSize = NSSize(
                    width: scrollView.contentSize.width, height: .greatestFiniteMagnitude
                )
                textView.isHorizontallyResizable = false
            } else {
                container.widthTracksTextView = false
                container.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
                )
                textView.maxSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
                )
                textView.isHorizontallyResizable = true
            }
        }
    }
}
