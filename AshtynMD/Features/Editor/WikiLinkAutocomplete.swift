import AppKit
import Observation
import SwiftUI

/// The unfinished wiki-link target immediately before the editor caret.
/// Ranges use UTF-16 offsets so they can be applied directly to NSTextView.
struct WikiLinkAutocompleteContext: Equatable {
    let openingRange: NSRange
    let targetRange: NSRange
    let rawQuery: String

    /// The trimmed form used for ranking and for the create-note title;
    /// `FuzzyMatch` additionally ignores whitespace inside the pattern, so
    /// "wee rev" still matches "Weekly Review". Keeping the raw value
    /// alongside it lets insertion replace exactly what the user typed.
    var query: String {
        rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func detect(in text: String, caretLocation: Int) -> Self? {
        let content = text as NSString
        let caret = min(max(caretLocation, 0), content.length)
        guard caret >= 2 else { return nil }

        let searchRange = NSRange(location: 0, length: caret)
        let opening = content.range(of: "[[", options: .backwards, range: searchRange)
        guard opening.location != NSNotFound,
              !isEscaped(opening.location, in: content) else {
            return nil
        }

        let targetStart = NSMaxRange(opening)
        let targetRange = NSRange(location: targetStart, length: caret - targetStart)
        let rawQuery = content.substring(with: targetRange)

        // A newline ends the target. A pipe switches to a display alias, and
        // a closer means the caret is no longer inside this wiki link.
        guard !rawQuery.contains("\n"),
              !rawQuery.contains("\r"),
              !rawQuery.contains("|"),
              !rawQuery.contains("]]"),
              !rawQuery.contains("[") else {
            return nil
        }

        return WikiLinkAutocompleteContext(
            openingRange: opening,
            targetRange: targetRange,
            rawQuery: rawQuery
        )
    }

    private static func isEscaped(_ location: Int, in content: NSString) -> Bool {
        var slashCount = 0
        var cursor = location - 1
        while cursor >= 0, content.character(at: cursor) == 0x5C {
            slashCount += 1
            cursor -= 1
        }
        return slashCount.isMultiple(of: 2) == false
    }
}

struct WikiLinkAutocompleteInsertion: Equatable {
    let range: NSRange
    let replacement: String

    var selectedRange: NSRange {
        NSRange(
            location: range.location + (replacement as NSString).length,
            length: 0
        )
    }
}

/// One ranked candidate in the popover: the underlying note, the character
/// ranges `FuzzyMatch` matched (for bolding), and its primary tag for the
/// secondary metadata line.
struct WikiLinkSuggestion: Equatable, Identifiable {
    let record: FileRecord
    let matchedRanges: [NSRange]
    let primaryTag: String?
    var id: Int64 { record.id }
}

/// What accepting the current selection does: always an insertion, plus a
/// note title to create on disk when the selection was the synthetic
/// "Create note" row.
struct WikiLinkAutocompleteAction: Equatable {
    let insertion: WikiLinkAutocompleteInsertion
    let noteToCreate: String?
}

/// Main-actor state machine for wiki-link suggestions. The lookup is injected
/// so trigger/range behavior and stale-result cancellation stay unit-testable
/// without opening a SQLite-backed library.
@MainActor
@Observable
final class WikiLinkAutocompleteModel {
    typealias SuggestionProvider = @MainActor (String, Int) async -> [WikiLinkSuggestion]

    static let debounce: Duration = .milliseconds(120)
    static let suggestionLimit = 20
    /// How many recency-ordered candidates the default provider fuzzy-ranks
    /// per lookup. `FuzzyMatch` is a DP matcher meant for "a few hundred
    /// short titles" (see its own doc comment), not a whole library.
    private static let candidatePoolSize = 500

    private let suggestionProvider: SuggestionProvider
    private let debounceDuration: Duration
    private let isAvailable: Bool
    private var lookupTask: Task<Void, Never>?
    private var requestID = 0

    private(set) var context: WikiLinkAutocompleteContext?
    private(set) var suggestions: [WikiLinkSuggestion] = []
    private(set) var selectedIndex = 0
    private(set) var isLoading = false
    var onChange: (() -> Void)?

    var isActive: Bool {
        context != nil
    }

    /// True once a non-empty query has settled with zero matches — the
    /// popover then offers a synthetic "Create note" row as the only slot.
    var showsCreateNoteRow: Bool {
        guard let context else { return false }
        return !isLoading && !context.query.isEmpty && suggestions.isEmpty
    }

    private var slotCount: Int {
        suggestions.count + (showsCreateNoteRow ? 1 : 0)
    }

    init(
        store: LibraryStore?,
        debounce: Duration = WikiLinkAutocompleteModel.debounce,
        suggestionProvider: SuggestionProvider? = nil
    ) {
        if let suggestionProvider {
            self.suggestionProvider = suggestionProvider
            isAvailable = true
        } else {
            self.suggestionProvider = { query, limit in
                guard let store else { return [] }
                guard !query.isEmpty else {
                    let recents = (try? await store.titleCandidates(limit: limit)) ?? []
                    return await Self.makeSuggestions(from: recents, store: store)
                }
                let candidates = (try? await store.titleCandidates(limit: Self.candidatePoolSize)) ?? []
                let ranked = candidates
                    .compactMap { record -> (record: FileRecord, score: FuzzyMatch.Score)? in
                        FuzzyMatch.score(pattern: query, in: record.title).map { (record, $0) }
                    }
                    .sorted { $0.score.value > $1.score.value }
                    .prefix(limit)
                let ranges = Dictionary(uniqueKeysWithValues: ranked.map { ($0.record.id, $0.score.ranges) })
                return await Self.makeSuggestions(
                    from: ranked.map(\.record),
                    matchedRanges: ranges,
                    store: store
                )
            }
            isAvailable = store != nil
        }
        self.debounceDuration = debounce
    }

    private static func makeSuggestions(
        from records: [FileRecord],
        matchedRanges: [Int64: [NSRange]] = [:],
        store: LibraryStore
    ) async -> [WikiLinkSuggestion] {
        var suggestions: [WikiLinkSuggestion] = []
        suggestions.reserveCapacity(records.count)
        for record in records {
            let tag = (try? await store.primaryTag(forFileID: record.id)) ?? nil
            suggestions.append(
                WikiLinkSuggestion(
                    record: record,
                    matchedRanges: matchedRanges[record.id] ?? [],
                    primaryTag: tag
                )
            )
        }
        return suggestions
    }

    func update(text: String, selection: NSRange, isMarkdown: Bool) {
        guard isAvailable,
              isMarkdown,
              selection.length == 0,
              let next = WikiLinkAutocompleteContext.detect(
                in: text,
                caretLocation: selection.location
              ) else {
            cancel()
            return
        }

        guard next != context else { return }

        requestID &+= 1
        let currentRequestID = requestID
        lookupTask?.cancel()
        context = next
        suggestions = []
        selectedIndex = 0
        isLoading = true
        onChange?()

        let provider = suggestionProvider
        let query = next.query
        lookupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.debounceDuration ?? .zero)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            let records = await provider(query, Self.suggestionLimit)
            guard !Task.isCancelled,
                  let self,
                  self.requestID == currentRequestID,
                  self.context == next else {
                return
            }

            self.suggestions = records
            self.selectedIndex = min(self.selectedIndex, max(0, records.count - 1))
            self.isLoading = false
            self.lookupTask = nil
            self.onChange?()
        }
    }

    func cancel() {
        let hadState = context != nil || !suggestions.isEmpty || isLoading
        requestID &+= 1
        lookupTask?.cancel()
        lookupTask = nil
        context = nil
        suggestions = []
        selectedIndex = 0
        isLoading = false
        if hadState { onChange?() }
    }

    func moveSelection(by offset: Int) {
        guard slotCount > 0 else { return }
        selectedIndex = (selectedIndex + offset).modulo(slotCount)
        onChange?()
    }

    func selectedAction() -> WikiLinkAutocompleteAction? {
        guard let context else { return nil }
        if let suggestion = suggestions[safe: selectedIndex] {
            let title = suggestion.record.title.isEmpty ? suggestion.record.name : suggestion.record.title
            guard !title.isEmpty else { return nil }
            return WikiLinkAutocompleteAction(
                insertion: WikiLinkAutocompleteInsertion(range: context.targetRange, replacement: title),
                noteToCreate: nil
            )
        }
        guard showsCreateNoteRow, selectedIndex == suggestions.count else { return nil }
        return WikiLinkAutocompleteAction(
            insertion: WikiLinkAutocompleteInsertion(range: context.targetRange, replacement: context.query),
            noteToCreate: context.query
        )
    }
}

@MainActor
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        let result = self % divisor
        return result >= 0 ? result : result + divisor
    }
}

/// SwiftUI content hosted by the AppKit popover. The editor remains first
/// responder, so arrows/Return/Tab continue to be handled by PlainTextView.
@MainActor
private struct WikiLinkAutocompletePopoverView: View {
    let model: WikiLinkAutocompleteModel
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isLoading && model.suggestions.isEmpty {
                ProgressView("Searching notes…")
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            } else if model.suggestions.isEmpty && !model.showsCreateNoteRow {
                Text("No matching notes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            row(
                                title: highlightedTitle(suggestion),
                                subtitle: subtitle(for: suggestion),
                                isSelected: index == model.selectedIndex,
                                identifier: AccessibilityID.wikiLinkSuggestion(index),
                                label: suggestion.record.title.isEmpty
                                    ? suggestion.record.name : suggestion.record.title
                            )
                        }
                        if model.showsCreateNoteRow, let context = model.context {
                            row(
                                title: AttributedString("Create note \u{201C}\(context.query)\u{201D}"),
                                subtitle: nil,
                                isSelected: model.selectedIndex == model.suggestions.count,
                                identifier: AccessibilityID.wikiLinkCreateNote,
                                label: "Create note \(context.query)"
                            )
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(6)
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.wikiLinkAutocomplete)
    }

    private func row(
        title: AttributedString,
        subtitle: String?,
        isSelected: Bool,
        identifier: String,
        label: String
    ) -> some View {
        Button {
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }

    private func subtitle(for suggestion: WikiLinkSuggestion) -> String {
        let tag = suggestion.primaryTag.map { "#\($0)" } ?? "Untagged"
        let date = suggestion.record.modifiedAt.formatted(.relative(presentation: .named))
        return "\(tag) · edited \(date)"
    }

    private func highlightedTitle(_ suggestion: WikiLinkSuggestion) -> AttributedString {
        let title = suggestion.record.title.isEmpty ? suggestion.record.name : suggestion.record.title
        let attributed = NSMutableAttributedString(string: title)
        let fullLength = (title as NSString).length
        for range in suggestion.matchedRanges {
            let bounded = NSRange(
                location: max(0, min(range.location, fullLength)),
                length: range.length
            )
            let clamped = NSRange(
                location: bounded.location,
                length: min(bounded.length, fullLength - bounded.location)
            )
            guard clamped.length > 0 else { continue }
            attributed.addAttribute(
                .font,
                value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                range: clamped
            )
        }
        return AttributedString(attributed)
    }
}

/// AppKit presentation and keyboard bridge for the SwiftUI suggestion list.
@MainActor
final class WikiLinkAutocompleteController: NSObject, NSPopoverDelegate {
    let model: WikiLinkAutocompleteModel
    private weak var textView: PlainTextView?
    private var popover: NSPopover?
    private var isDismissing = false
    private let store: LibraryStore?
    private let noteDirectory: () -> URL?
    private let reindex: (() -> Void)?
    private let reportError: ((String) -> Void)?

    init(
        textView: PlainTextView,
        store: LibraryStore?,
        noteDirectory: @escaping () -> URL? = { nil },
        reindex: (() -> Void)? = nil,
        reportError: ((String) -> Void)? = nil
    ) {
        model = WikiLinkAutocompleteModel(store: store)
        self.store = store
        self.textView = textView
        self.noteDirectory = noteDirectory
        self.reindex = reindex
        self.reportError = reportError
        super.init()
        model.onChange = { [weak self] in
            self?.modelDidChange()
        }
    }

    func update() {
        guard let textView else {
            dismiss()
            return
        }
        model.update(
            text: textView.string,
            selection: textView.selectedRange(),
            isMarkdown: textView.languageDefinition?.id == .markdown
        )
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard model.isActive else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty else { return false }

        switch event.keyCode {
        case 126: // Up
            model.moveSelection(by: -1)
            return true
        case 125: // Down
            model.moveSelection(by: 1)
            return true
        case 36, 76: // Return, keypad Enter
            return acceptSelection()
        case 53: // Escape
            dismiss()
            return true
        default:
            return false
        }
    }

    func acceptSelection() -> Bool {
        guard let action = model.selectedAction(), let textView else { return false }
        let insertion = action.insertion
        dismiss()
        // Bracket auto-pairing (PlainTextView.insertText) already leaves a
        // closing "]]" after the caret in the common case of typing "[["
        // fresh — but not when "[[" was typed immediately before other
        // text, so auto-pairing didn't fire. Only append what's missing.
        let replacement = hasClosingBrackets(after: insertion.range, in: textView)
            ? insertion.replacement
            : insertion.replacement + "]]"
        guard textView.applyExternalEdit(
            range: insertion.range,
            replacement: replacement
        ) else {
            return false
        }
        // `selectedRange` is computed from the title-only replacement, so it
        // lands the caret right after the title regardless of whether "]]"
        // was already present or just appended above.
        textView.setSelectedRange(insertion.selectedRange)
        textView.scrollRangeToVisible(insertion.selectedRange)
        if let title = action.noteToCreate {
            createNote(titled: title)
        }
        return true
    }

    private func hasClosingBrackets(after range: NSRange, in textView: PlainTextView) -> Bool {
        let content = textView.string as NSString
        let closerRange = NSRange(location: NSMaxRange(range), length: 2)
        guard closerRange.location + closerRange.length <= content.length else { return false }
        return content.substring(with: closerRange) == "]]"
    }

    /// The duplicate check has to reach the actor-backed store, so creation
    /// hops off the accept path. Captures self strongly on purpose: the user
    /// asked for this note, and a controller torn down in the same run loop
    /// must not silently swallow it.
    private func createNote(titled title: String) {
        Task {
            await self.createNoteIfMissing(titled: title)
        }
    }

    /// Creates the note unless the library already has one with this exact
    /// title. The create-note row only reflects the fuzzy-ranked candidate
    /// pool, which `LibraryStore.titleCandidates` caps at 500 recency-ordered
    /// notes — in a larger library an older note with this very title can sit
    /// outside that window and still be offered for "creation". The inserted
    /// `[[title]]` already resolves to it by title key, so the right move is
    /// to write nothing at all rather than a colliding duplicate.
    ///
    /// Not private so controller tests can drive it without racing the
    /// detached task `createNote(titled:)` spawns.
    func createNoteIfMissing(titled title: String) async {
        if let store {
            let key = MarkdownMetadata.foldTitle(title)
            // A lookup failure falls through to creating the note: the same
            // outcome as before this guard existed.
            let existing = (try? await store.resolveWikiLink(key)) ?? []
            guard existing.isEmpty else { return }
        }
        guard let folder = noteDirectory(),
              let baseName = TitleFilename.sanitizedBaseName(title) else { return }
        let url = LibraryBrowser.availableURL(in: folder, baseName: baseName, ext: "md")
        do {
            try SaveCoordinator.writeAtomically(Data("\(title)\n".utf8), to: url)
            reindex?()
        } catch {
            reportError?("Couldn't create \u{201C}\(baseName).md\u{201D}: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func dismiss() -> Bool {
        let wasActive = model.isActive || popover?.isShown == true
        isDismissing = true
        model.cancel()
        popover?.close()
        isDismissing = false
        return wasActive
    }

    func popoverDidClose(_ notification: Notification) {
        guard !isDismissing else { return }
        model.cancel()
    }

    private func modelDidChange() {
        guard model.isActive, let textView, textView.window != nil else {
            popover?.close()
            return
        }

        if popover == nil {
            let content = WikiLinkAutocompletePopoverView(
                model: model,
                onSelect: { [weak self] in
                    _ = self?.acceptSelection()
                }
            )
            let hostingController = NSHostingController(rootView: content)
            let popover = NSPopover()
            popover.contentViewController = hostingController
            popover.behavior = .semitransient
            popover.animates = false
            popover.delegate = self
            popover.contentSize = NSSize(width: 332, height: 280)
            self.popover = popover
        }

        let caret = textView.selectedRange()
        let screenRect = textView.firstRect(forCharacterRange: caret, actualRange: nil)
        let windowRect = textView.window?.convertFromScreen(screenRect) ?? .zero
        let positioningRect = textView.convert(windowRect, from: nil)
        popover?.show(
            relativeTo: positioningRect,
            of: textView,
            preferredEdge: .maxY
        )
    }
}
