import Foundation

/// Locates GFM task-list markers in Markdown source so a preview checkbox
/// click can be translated into an exact, undoable source edit.
enum MarkdownTasks {
    struct TaskMarker: Equatable {
        /// UTF-16 range of the bracket content: the single character between
        /// "[" and "]".
        let stateRange: NSRange
        /// `[x]` including the brackets. Click hit-testing in the editor needs
        /// a target bigger than one character.
        let bracketRange: NSRange
        /// The whole line holding the marker.
        let lineRange: NSRange
        let isChecked: Bool
    }

    private static let markerRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*+]|\d+[.)])\s+\[([ xX])\]\s"#,
        options: [.anchorsMatchLines]
    )

    /// All task markers in source order. The Nth preview checkbox corresponds
    /// to the Nth marker here (both walk the document top to bottom).
    static func markers(in source: String) -> [TaskMarker] {
        let ns = source as NSString
        var results: [TaskMarker] = []
        markerRegex.enumerateMatches(
            in: source, range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let match else { return }
            let stateRange = match.range(at: 1)
            let state = ns.substring(with: stateRange).lowercased()
            results.append(
                TaskMarker(
                    stateRange: stateRange,
                    bracketRange: NSRange(location: stateRange.location - 1, length: 3),
                    lineRange: ns.lineRange(for: stateRange),
                    isChecked: state == "x"
                )
            )
        }
        return results
    }

    /// The source edit that toggles task number `index`, or nil if out of range.
    static func toggleEdit(forTaskAt index: Int, in source: String) -> (range: NSRange, replacement: String)? {
        let all = markers(in: source)
        guard index >= 0, index < all.count else { return nil }
        let marker = all[index]
        return (marker.stateRange, marker.isChecked ? " " : "x")
    }
}
