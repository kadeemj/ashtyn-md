import Foundation

/// Highlight markers for FTS5 `snippet()` output, and the parser that turns
/// a delimited snippet string into renderable segments.
///
/// The markers are private-use-area scalars, not visible punctuation like
/// `⟦`/`⟧`: FTS5's `snippet()` does not escape its own markers, so a note
/// containing one of the marker characters in its own text would otherwise
/// corrupt the parse.
enum SearchSnippet {
    static let openMarker: Character = "\u{E000}"
    static let closeMarker: Character = "\u{E001}"

    struct Segment: Equatable {
        let text: String
        let isHighlighted: Bool
    }

    /// Splits a snippet string into plain/highlighted runs. Never throws:
    /// content that survives to end-of-string was never followed by a close
    /// marker. In well-formed FTS5 output that only happens for ordinary
    /// trailing plain text; if an open marker was itself never closed
    /// (malformed input), the same fallback keeps that remainder from being
    /// guessed at as highlighted.
    static func segments(from raw: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var isHighlighted = false

        for character in raw {
            switch character {
            case openMarker:
                if !current.isEmpty {
                    segments.append(Segment(text: current, isHighlighted: isHighlighted))
                    current = ""
                }
                isHighlighted = true
            case closeMarker:
                if !current.isEmpty {
                    segments.append(Segment(text: current, isHighlighted: isHighlighted))
                    current = ""
                }
                isHighlighted = false
            default:
                current.append(character)
            }
        }
        if !current.isEmpty {
            segments.append(Segment(text: current, isHighlighted: false))
        }
        return segments
    }
}
