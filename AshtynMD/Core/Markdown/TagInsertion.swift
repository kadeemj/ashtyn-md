import Foundation

/// Where to put a tag when one is dropped onto a note.
///
/// Pure so the placement rules are testable without a document or a drag.
enum TagInsertion {
    /// Returns the edit that adds `tag` to `text`, or nil when it is already
    /// there.
    ///
    /// `tag` includes the leading `#`.
    static func plan(for tag: String, in text: String) -> TextEdit? {
        let key = MarkdownTag.fold(String(tag.dropFirst()))
        guard !key.isEmpty else { return nil }

        let nsText = text as NSString
        let existing = MarkdownTagScanner.tags(in: nsText)
        // Already tagged, or already covered by a more specific tag.
        if existing.contains(where: { $0.key == key || $0.key.hasPrefix(key + "/") }) {
            return nil
        }

        let source = MarkdownSource(nsText)
        // In-memory text is always LF — LoadedTextFile normalizes on load and
        // the original style is reapplied on save. Detecting line endings here
        // would be both wrong and unnecessary.
        let newline = "\n"

        // Append to a trailing line that holds nothing but tags, so repeated
        // drops collect rather than stacking blocks.
        if let lastContent = lastNonBlankLine(source),
           isPureTagLine(source: source, line: lastContent, tags: existing),
           lastContent.location > source.line(0).location {
            return TextEdit(
                range: NSRange(location: NSMaxRange(lastContent), length: 0),
                replacement: " " + tag,
                selection: NSRange(location: NSMaxRange(lastContent), length: 0)
            )
        }

        // Otherwise append a fresh tag block. Never the first line: that is the
        // title, and now also the filename.
        let end = nsText.length
        let needsBlankLine = end > 0
        let prefix = needsBlankLine
            ? (nsText.hasSuffix(newline) ? newline : newline + newline)
            : ""
        let replacement = prefix + tag + newline
        return TextEdit(
            range: NSRange(location: end, length: 0),
            replacement: replacement,
            selection: NSRange(location: end, length: 0)
        )
    }

    private static func lastNonBlankLine(_ source: MarkdownSource) -> NSRange? {
        for index in stride(from: source.lineCount - 1, through: 0, by: -1) {
            let line = source.line(index)
            let hasContent = (line.location..<NSMaxRange(line)).contains {
                !source[$0].isMarkdownWhitespace
            }
            if hasContent { return line }
        }
        return nil
    }

    private static func isPureTagLine(
        source: MarkdownSource,
        line: NSRange,
        tags: [MarkdownTag]
    ) -> Bool {
        let onLine = tags.filter { NSIntersectionRange($0.range, line).length > 0 }
        guard !onLine.isEmpty else { return false }
        var cursor = line.location
        for tag in onLine.sorted(by: { $0.range.location < $1.range.location }) {
            while cursor < NSMaxRange(line), source[cursor].isMarkdownWhitespace { cursor += 1 }
            guard tag.range.location == cursor else { return false }
            cursor = NSMaxRange(tag.range)
        }
        while cursor < NSMaxRange(line), source[cursor].isMarkdownWhitespace { cursor += 1 }
        return cursor >= NSMaxRange(line)
    }
}

private extension NSString {
    func hasSuffix(_ suffix: String) -> Bool {
        (self as String).hasSuffix(suffix)
    }
}
