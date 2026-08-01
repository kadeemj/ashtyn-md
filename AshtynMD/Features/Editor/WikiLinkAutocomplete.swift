import AppKit
import Observation
import SwiftUI

/// The unfinished wiki-link target immediately before the editor caret.
/// Ranges use UTF-16 offsets so they can be applied directly to NSTextView.
struct WikiLinkAutocompleteContext: Equatable {
    let openingRange: NSRange
    let targetRange: NSRange
    let rawQuery: String

    /// Whitespace is folded by `LibraryStore.titleSuggestions`; keeping the
    /// raw value separately lets insertion replace exactly what the user typed.
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

/// Main-actor state machine for wiki-link suggestions. The lookup is injected
/// so trigger/range behavior and stale-result cancellation stay unit-testable
/// without opening a SQLite-backed library.
@MainActor
@Observable
final class WikiLinkAutocompleteModel {
    typealias SuggestionProvider = @MainActor (String, Int) async -> [FileRecord]

    static let debounce: Duration = .milliseconds(120)
    static let suggestionLimit = 20

    private let suggestionProvider: SuggestionProvider
    private let debounceDuration: Duration
    private let isAvailable: Bool
    private var lookupTask: Task<Void, Never>?
    private var requestID = 0

    private(set) var context: WikiLinkAutocompleteContext?
    private(set) var suggestions: [FileRecord] = []
    private(set) var selectedIndex = 0
    private(set) var isLoading = false
    var onChange: (() -> Void)?

    var isActive: Bool {
        guard let context else { return false }
        return !context.query.isEmpty
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
            self.suggestionProvider = { prefix, limit in
                guard let store else { return [] }
                return (try? await store.titleSuggestions(prefix: prefix, limit: limit)) ?? []
            }
            isAvailable = store != nil
        }
        self.debounceDuration = debounce
    }

    func update(text: String, selection: NSRange, isMarkdown: Bool) {
        guard isAvailable,
              isMarkdown,
              selection.length == 0,
              let next = WikiLinkAutocompleteContext.detect(
                in: text,
                caretLocation: selection.location
              ),
              !next.query.isEmpty else {
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
        guard !suggestions.isEmpty else { return }
        let count = suggestions.count
        selectedIndex = (selectedIndex + offset).modulo(count)
        onChange?()
    }

    func selectedInsertion() -> WikiLinkAutocompleteInsertion? {
        guard let context, let record = suggestions[safe: selectedIndex] else { return nil }
        let title = record.title.isEmpty ? record.name : record.title
        guard !title.isEmpty else { return nil }
        return WikiLinkAutocompleteInsertion(range: context.targetRange, replacement: title)
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
            } else if model.suggestions.isEmpty {
                Text("No matching notes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            } else {
                ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, record in
                    Button {
                        onSelect()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title.isEmpty ? record.name : record.title)
                                .lineLimit(1)
                            Text(record.relativePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            index == model.selectedIndex
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.wikiLinkSuggestion(index))
                    .accessibilityLabel(record.title.isEmpty ? record.name : record.title)
                }
            }
        }
        .padding(6)
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.wikiLinkAutocomplete)
    }
}

/// AppKit presentation and keyboard bridge for the SwiftUI suggestion list.
@MainActor
final class WikiLinkAutocompleteController: NSObject, NSPopoverDelegate {
    let model: WikiLinkAutocompleteModel
    private weak var textView: PlainTextView?
    private var popover: NSPopover?
    private var isDismissing = false

    init(textView: PlainTextView, store: LibraryStore?) {
        model = WikiLinkAutocompleteModel(store: store)
        self.textView = textView
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
        guard let insertion = model.selectedInsertion(), let textView else { return false }
        dismiss()
        guard textView.applyExternalEdit(
            range: insertion.range,
            replacement: insertion.replacement
        ) else {
            return false
        }
        textView.setSelectedRange(insertion.selectedRange)
        textView.scrollRangeToVisible(insertion.selectedRange)
        dismiss()
        return true
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
            popover.contentSize = NSSize(width: 332, height: 120)
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
