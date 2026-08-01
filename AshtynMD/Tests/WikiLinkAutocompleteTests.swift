import Foundation
import Testing

@testable import AshtynMD

@Suite("Wiki-link autocomplete triggers")
struct WikiLinkAutocompleteContextTests {
    @Test("finds a target range that includes spaces")
    func targetRangeIncludesSpaces() {
        let text = "See [[Weekly Re"
        let context = WikiLinkAutocompleteContext.detect(
            in: text,
            caretLocation: (text as NSString).length
        )

        #expect(context?.openingRange == NSRange(location: 4, length: 2))
        #expect(context?.targetRange == NSRange(location: 6, length: 9))
        #expect(context?.rawQuery == "Weekly Re")
        #expect(context?.query == "Weekly Re")
    }

    @Test("does not trigger after a completed link or inside an alias")
    func completedLinkAndAliasAreInactive() {
        let complete = "See [[Weekly Review]]"
        #expect(
            WikiLinkAutocompleteContext.detect(
                in: complete,
                caretLocation: (complete as NSString).length
            ) == nil
        )

        let alias = "See [[Weekly Review|last week]]"
        #expect(
            WikiLinkAutocompleteContext.detect(
                in: alias,
                caretLocation: (alias as NSString).length
            ) == nil
        )
    }

    @Test("does not trigger across a newline or an escaped opening")
    func invalidContextsAreInactive() {
        let multiline = "[[Weekly\nReview"
        #expect(
            WikiLinkAutocompleteContext.detect(
                in: multiline,
                caretLocation: (multiline as NSString).length
            ) == nil
        )

        let escaped = #"\[[Weekly Re"#
        #expect(
            WikiLinkAutocompleteContext.detect(
                in: escaped,
                caretLocation: (escaped as NSString).length
            ) == nil
        )
    }
}

@Suite("Wiki-link autocomplete model", .serialized)
@MainActor
struct WikiLinkAutocompleteModelTests {
    private func record(_ title: String, id: Int64 = 1) -> FileRecord {
        FileRecord(
            id: id,
            relativePath: "\(title).md",
            name: "\(title).md",
            size: 0,
            modifiedAt: Date(timeIntervalSince1970: Double(id)),
            contentHash: nil,
            languageID: .markdown,
            resourceID: nil,
            isFavorite: false,
            lastOpenedAt: nil,
            title: title,
            titleKey: MarkdownMetadata.foldTitle(title)
        )
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
    }

    @Test("debounces lookup and inserts the selected title")
    func insertionUsesTheTargetRange() async {
        let expected = record("Weekly Review")
        let model = WikiLinkAutocompleteModel(
            store: nil,
            debounce: .milliseconds(10),
            suggestionProvider: { _, _ in [expected] }
        )
        let text = "See [[Weekly Re]]"
        let caret = (text as NSString).range(of: "]]", options: [], range: NSRange(location: 0, length: (text as NSString).length)).location

        model.update(
            text: text,
            selection: NSRange(location: caret, length: 0),
            isMarkdown: true
        )
        await settle()

        #expect(model.suggestions.map(\.title) == ["Weekly Review"])
        let insertion = model.selectedInsertion()
        #expect(insertion?.range == NSRange(location: 6, length: 9))
        #expect(insertion?.replacement == "Weekly Review")
        #expect(insertion?.selectedRange == NSRange(location: 19, length: 0))
    }

    @Test("empty results finish cleanly without a stale selection")
    func emptyResults() async {
        let model = WikiLinkAutocompleteModel(
            store: nil,
            debounce: .milliseconds(10),
            suggestionProvider: { _, _ in [] }
        )
        let text = "[[Missing Note"
        model.update(
            text: text,
            selection: NSRange(location: (text as NSString).length, length: 0),
            isMarkdown: true
        )
        await settle()

        #expect(model.isActive)
        #expect(!model.isLoading)
        #expect(model.suggestions.isEmpty)
        #expect(model.selectedInsertion() == nil)
    }

    @Test("standalone documents do not query without a library store")
    func unavailableWithoutStore() {
        let model = WikiLinkAutocompleteModel(store: nil, debounce: .milliseconds(0))
        model.update(
            text: "[[Library Note",
            selection: NSRange(location: 14, length: 0),
            isMarkdown: true
        )

        #expect(!model.isActive)
        #expect(model.suggestions.isEmpty)
        #expect(!model.isLoading)
    }

    @Test("a newer query wins over a cancelled older lookup")
    func cancellationPreventsStaleResults() async {
        let old = record("Old Note")
        let new = record("New Note", id: 2)
        let model = WikiLinkAutocompleteModel(
            store: nil,
            debounce: .milliseconds(0),
            suggestionProvider: { prefix, _ in
                if prefix == "Old" {
                    try? await Task.sleep(for: .milliseconds(140))
                    return [old]
                }
                return [new]
            }
        )

        model.update(
            text: "[[Old",
            selection: NSRange(location: 5, length: 0),
            isMarkdown: true
        )
        try? await Task.sleep(for: .milliseconds(20))
        model.update(
            text: "[[New",
            selection: NSRange(location: 5, length: 0),
            isMarkdown: true
        )
        await settle()

        #expect(model.suggestions.map(\.title) == ["New Note"])
        try? await Task.sleep(for: .milliseconds(160))
        #expect(model.suggestions.map(\.title) == ["New Note"])
    }

    @Test("selection navigation wraps around the result list")
    func keyboardNavigation() async {
        let model = WikiLinkAutocompleteModel(
            store: nil,
            debounce: .milliseconds(0),
            suggestionProvider: { _, _ in
                [self.record("One"), self.record("Two", id: 2)]
            }
        )
        model.update(
            text: "[[O",
            selection: NSRange(location: 3, length: 0),
            isMarkdown: true
        )
        await settle()

        model.moveSelection(by: 1)
        #expect(model.selectedIndex == 1)
        model.moveSelection(by: 1)
        #expect(model.selectedIndex == 0)
        model.moveSelection(by: -1)
        #expect(model.selectedIndex == 1)
    }
}
