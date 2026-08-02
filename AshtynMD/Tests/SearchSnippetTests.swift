import Testing

@testable import AshtynMD

@Suite("Search snippet highlight parsing")
struct SearchSnippetTests {
    private let open = String(SearchSnippet.openMarker)
    private let close = String(SearchSnippet.closeMarker)

    @Test("an empty string produces no segments")
    func emptyStringProducesNoSegments() {
        #expect(SearchSnippet.segments(from: "") == [])
    }

    @Test("plain text with no markers is one unhighlighted segment")
    func noMarkersIsOnePlainSegment() {
        #expect(
            SearchSnippet.segments(from: "no markers here")
                == [.init(text: "no markers here", isHighlighted: false)]
        )
    }

    @Test("one highlighted span between plain runs")
    func oneHighlightedSpan() {
        let raw = "before \(open)middle\(close) after"
        #expect(
            SearchSnippet.segments(from: raw) == [
                .init(text: "before ", isHighlighted: false),
                .init(text: "middle", isHighlighted: true),
                .init(text: " after", isHighlighted: false),
            ]
        )
    }

    @Test("multiple highlighted spans")
    func multipleHighlightedSpans() {
        let raw = "\(open)one\(close) two \(open)three\(close)"
        #expect(
            SearchSnippet.segments(from: raw) == [
                .init(text: "one", isHighlighted: true),
                .init(text: " two ", isHighlighted: false),
                .init(text: "three", isHighlighted: true),
            ]
        )
    }

    @Test("the FTS5 ellipsis marker passes through as ordinary plain text")
    func ellipsisPassesThroughAsPlainText() {
        #expect(
            SearchSnippet.segments(from: "…\(open)hit\(close)…") == [
                .init(text: "…", isHighlighted: false),
                .init(text: "hit", isHighlighted: true),
                .init(text: "…", isHighlighted: false),
            ]
        )
    }

    @Test("an unterminated open marker degrades its remainder to plain text")
    func unterminatedOpenMarkerDegradesToPlain() {
        let raw = "before \(open)unterminated"
        #expect(
            SearchSnippet.segments(from: raw) == [
                .init(text: "before ", isHighlighted: false),
                .init(text: "unterminated", isHighlighted: false),
            ]
        )
    }
}
