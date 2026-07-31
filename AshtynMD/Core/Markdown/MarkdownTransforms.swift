import Foundation

/// One replacement plus where the selection should land afterwards.
///
/// Keeping the commands as pure functions returning this means all the offset
/// arithmetic — the part that is easy to get subtly wrong across multi-line
/// selections — is unit-testable without an NSTextView.
struct TextEdit: Sendable, Equatable {
    /// Range in the *original* text.
    let range: NSRange
    let replacement: String
    /// Selection after applying, in the *new* text.
    let selection: NSRange
}

enum MarkdownInlineStyle: Sendable, CaseIterable {
    case bold
    case italic
    case inlineCode
    case strikethrough

    var delimiter: String {
        switch self {
        case .bold: return "**"
        case .italic: return "_"
        case .inlineCode: return "`"
        case .strikethrough: return "~~"
        }
    }

    /// Alternate spellings that count as the same style when unwrapping, so
    /// `*italic*` toggles off even though we write `_italic_`.
    var recognizedDelimiters: [String] {
        switch self {
        case .bold: return ["**", "__"]
        case .italic: return ["_", "*"]
        case .inlineCode: return ["`"]
        case .strikethrough: return ["~~"]
        }
    }
}

enum MarkdownInlineTransform {
    /// Wraps, unwraps, or inserts a delimiter pair.
    static func toggle(
        _ style: MarkdownInlineStyle,
        in text: NSString,
        selection: NSRange
    ) -> TextEdit? {
        let clamped = clamp(selection, to: text)

        // Multi-line selections wrap each line's content separately: emphasis
        // cannot span a line break in CommonMark, so one outer pair would
        // silently fail to render.
        if clamped.length > 0, text.substring(with: clamped).contains("\n") {
            return wrapPerLine(style, in: text, selection: clamped)
        }

        if let existing = enclosingRun(style, in: text, selection: clamped) {
            return unwrap(existing, in: text)
        }

        var target = clamped
        if target.length == 0 {
            target = wordRange(in: text, at: clamped.location) ?? clamped
        }
        if target.length == 0 {
            let delimiter = style.delimiter
            return TextEdit(
                range: target,
                replacement: delimiter + delimiter,
                selection: NSRange(location: target.location + delimiter.count, length: 0)
            )
        }

        // Push whitespace outside the delimiters — `**word **` is not emphasis.
        let trimmed = trimmingWhitespace(target, in: text)
        guard trimmed.length > 0 else {
            let delimiter = style.delimiter
            return TextEdit(
                range: NSRange(location: target.location, length: 0),
                replacement: delimiter + delimiter,
                selection: NSRange(location: target.location + delimiter.count, length: 0)
            )
        }

        let delimiter = style.delimiter
        let content = text.substring(with: trimmed)
        return TextEdit(
            range: trimmed,
            replacement: delimiter + content + delimiter,
            selection: NSRange(
                location: trimmed.location + delimiter.count,
                length: (content as NSString).length
            )
        )
    }

    /// `[label](destination)`, or unwraps an existing link at the caret.
    static func link(
        in text: NSString,
        selection: NSRange,
        clipboardURL: String?
    ) -> TextEdit? {
        let clamped = clamp(selection, to: text)

        if let existing = enclosingLink(in: text, at: clamped.location) {
            let label = existing.label.length > 0 ? text.substring(with: existing.label) : ""
            return TextEdit(
                range: existing.full,
                replacement: label,
                selection: NSRange(location: existing.full.location, length: (label as NSString).length)
            )
        }

        let url = clipboardURL.flatMap(normalizedURL) ?? ""
        var target = clamped
        if target.length > 0 {
            target = trimmingWhitespace(target, in: text)
        }
        let label = target.length > 0 ? text.substring(with: target) : ""
        let replacement = "[\(label)](\(url))"

        let selectionAfter: NSRange
        if label.isEmpty {
            // Caret in the label — the destination is already known or empty.
            selectionAfter = NSRange(location: target.location + 1, length: 0)
        } else if url.isEmpty {
            // Caret in the destination, ready for a paste.
            selectionAfter = NSRange(
                location: target.location + 1 + (label as NSString).length + 2,
                length: 0
            )
        } else {
            selectionAfter = NSRange(
                location: target.location + (replacement as NSString).length,
                length: 0
            )
        }
        return TextEdit(range: target, replacement: replacement, selection: selectionAfter)
    }

    /// Accepts a scheme-prefixed string or a bare `www.` host.
    static func normalizedURL(_ candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isNewline }) else { return nil }
        if trimmed.lowercased().hasPrefix("www.") { return trimmed }
        guard let schemeEnd = trimmed.firstIndex(of: ":"), schemeEnd > trimmed.startIndex else {
            return nil
        }
        let scheme = trimmed[trimmed.startIndex..<schemeEnd]
        guard scheme.first?.isLetter == true,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        return trimmed
    }

    // MARK: - Helpers

    private static func wrapPerLine(
        _ style: MarkdownInlineStyle,
        in text: NSString,
        selection: NSRange
    ) -> TextEdit? {
        let block = text.lineRange(for: selection)
        let source = text.substring(with: block)
        let hadTrailingNewline = source.hasSuffix("\n")
        var lines = source.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }

        let delimiter = style.delimiter
        let wrapped = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            guard let range = line.range(of: trimmed) else { return line }
            return line.replacingCharacters(in: range, with: delimiter + trimmed + delimiter)
        }
        var replacement = wrapped.joined(separator: "\n")
        if hadTrailingNewline { replacement += "\n" }

        return TextEdit(
            range: block,
            replacement: replacement,
            selection: NSRange(location: block.location, length: (replacement as NSString).length)
        )
    }

    private struct Run {
        let full: NSRange
        let content: NSRange
    }

    /// Finds a delimiter pair of `style` that encloses the selection.
    private static func enclosingRun(
        _ style: MarkdownInlineStyle,
        in text: NSString,
        selection: NSRange
    ) -> Run? {
        let line = text.lineRange(for: NSRange(location: min(selection.location, text.length), length: 0))
        let lineText = text.substring(with: line) as NSString

        for delimiter in style.recognizedDelimiters {
            let token = delimiter as NSString
            var searchStart = 0
            var openings: [Int] = []
            while searchStart + token.length <= lineText.length {
                let found = lineText.range(
                    of: delimiter,
                    options: [],
                    range: NSRange(location: searchStart, length: lineText.length - searchStart)
                )
                guard found.location != NSNotFound else { break }
                openings.append(found.location)
                searchStart = found.location + token.length
            }
            // Pair them up in order.
            var index = 0
            while index + 1 < openings.count {
                let open = openings[index]
                let close = openings[index + 1]
                let contentStart = open + token.length
                guard close > contentStart else {
                    index += 1
                    continue
                }
                let fullStart = line.location + open
                let fullLength = close + token.length - open
                let full = NSRange(location: fullStart, length: fullLength)
                let content = NSRange(
                    location: line.location + contentStart,
                    length: close - contentStart
                )
                // A caret anywhere inside, or a selection covering the content.
                let insideContent = selection.length == 0
                    ? (content.location <= selection.location && selection.location <= NSMaxRange(content))
                    : NSIntersectionRange(content, selection).length == selection.length
                if insideContent {
                    // For a single-character delimiter, make sure this is not
                    // really the inner half of a longer run (`**` seen as `_`).
                    if token.length == 1, isPartOfLongerRun(lineText, at: open, token: token) {
                        index += 2
                        continue
                    }
                    return Run(full: full, content: content)
                }
                index += 2
            }
        }
        return nil
    }

    private static func isPartOfLongerRun(
        _ line: NSString,
        at location: Int,
        token: NSString
    ) -> Bool {
        let character = token.character(at: 0)
        if location > 0, line.character(at: location - 1) == character { return true }
        if location + 1 < line.length, line.character(at: location + 1) == character { return true }
        return false
    }

    private static func unwrap(_ run: Run, in text: NSString) -> TextEdit {
        let content = text.substring(with: run.content)
        return TextEdit(
            range: run.full,
            replacement: content,
            selection: NSRange(location: run.full.location, length: (content as NSString).length)
        )
    }

    private struct LinkMatch {
        let full: NSRange
        let label: NSRange
    }

    private static func enclosingLink(in text: NSString, at location: Int) -> LinkMatch? {
        guard text.length > 0 else { return nil }
        let source = MarkdownSource(text)
        let mask = MarkdownMaskIndex.build(source: source, lines: 0..<source.lineCount)
        for link in mask.links where link.kind == .inline || link.kind == .image {
            if NSLocationInRange(location, link.full)
                || NSMaxRange(link.full) == location {
                return LinkMatch(full: link.full, label: link.text ?? NSRange(location: link.full.location, length: 0))
            }
        }
        return nil
    }

    private static func wordRange(in text: NSString, at location: Int) -> NSRange? {
        guard text.length > 0 else { return nil }
        let line = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        var start = min(location, NSMaxRange(line))
        var end = start

        func isWord(_ index: Int) -> Bool {
            guard index >= line.location, index < NSMaxRange(line) else { return false }
            let character = text.character(at: index)
            return character.isMarkdownWordCharacter
        }

        while start > line.location, isWord(start - 1) { start -= 1 }
        while end < NSMaxRange(line), isWord(end) { end += 1 }
        guard end > start else { return NSRange(location: location, length: 0) }
        return NSRange(location: start, length: end - start)
    }

    private static func trimmingWhitespace(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, text.character(at: start).isMarkdownWhitespace { start += 1 }
        while end > start, text.character(at: end - 1).isMarkdownWhitespace { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func clamp(_ range: NSRange, to text: NSString) -> NSRange {
        let location = min(max(range.location, 0), text.length)
        let length = min(range.length, text.length - location)
        return NSRange(location: location, length: length)
    }
}

// MARK: - Block transforms

enum MarkdownBlockTransform {
    static func setHeading(level: Int, in text: NSString, selection: NSRange) -> TextEdit? {
        transformLines(in: text, selection: selection) { lines in
            let clampedLevel = min(max(level, 1), 6)
            let marker = String(repeating: "#", count: clampedLevel) + " "
            // Applying the level a line already has strips it, so the same
            // shortcut is both apply and remove.
            let allAtLevel = lines
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .allSatisfy { headingLevel(of: $0) == clampedLevel }

            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                let parts = splitQuotePrefix(line)
                // Quote markers survive; list markers do not.
                let body = stripListMarker(stripHeadingMarker(parts.body))
                return parts.prefix + (allAtLevel ? body : marker + body)
            }
        }
    }

    static func clearBlockStyle(in text: NSString, selection: NSRange) -> TextEdit? {
        transformLines(in: text, selection: selection) { lines in
            lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                var body = splitQuotePrefix(line).body
                body = stripHeadingMarker(body)
                body = stripListMarker(body)
                return body
            }
        }
    }

    static func toggleQuote(in text: NSString, selection: NSRange) -> TextEdit? {
        transformLines(in: text, selection: selection) { lines in
            let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            // Only unquote when every line is quoted; a mixed selection quotes.
            let allQuoted = !content.isEmpty && content.allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(">")
            }
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                if allQuoted {
                    var trimmed = line.trimmingCharacters(in: .whitespaces)
                    trimmed.removeFirst()
                    if trimmed.hasPrefix(" ") { trimmed.removeFirst() }
                    return trimmed
                }
                return "> " + line
            }
        }
    }

    static func toggleList(ordered: Bool, in text: NSString, selection: NSRange) -> TextEdit? {
        transformLines(in: text, selection: selection) { lines in
            let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let allMatching = !content.isEmpty && content.allSatisfy {
                ordered ? isOrderedItem($0) : isBulletItem($0)
            }

            var number = 0
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                let indent = leadingWhitespace(line)
                let body = stripListMarker(String(line.dropFirst(indent.count)))
                if allMatching { return indent + body }
                number += 1
                return indent + (ordered ? "\(number). " : "- ") + body
            }
        }
    }

    static func toggleTask(in text: NSString, selection: NSRange) -> TextEdit? {
        transformLines(in: text, selection: selection) { lines in
            let tasks = lines.filter { taskState(of: $0) != nil }
            let allChecked = !tasks.isEmpty && tasks.allSatisfy { taskState(of: $0) == true }

            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                if let checked = taskState(of: line) {
                    let target = allChecked ? " " : (checked ? "x" : "x")
                    return replacingTaskState(line, with: target)
                }
                let indent = leadingWhitespace(line)
                let rest = String(line.dropFirst(indent.count))
                if isBulletItem(rest) || isOrderedItem(rest) {
                    // Keep the existing marker, just add the checkbox.
                    let markerLength = listMarkerLength(rest)
                    let marker = String(rest.prefix(markerLength))
                    return indent + marker + "[ ] " + String(rest.dropFirst(markerLength))
                }
                return indent + "- [ ] " + rest
            }
        }
    }

    static func divider(in text: NSString, selection: NSRange) -> TextEdit? {
        let location = min(max(selection.location, 0), text.length)
        let line = text.lineRange(for: NSRange(location: min(location, max(0, text.length - 1)), length: 0))
        var insertAt = text.length == 0 ? 0 : NSMaxRange(line)

        // Swallow blank lines either side so repeated use cannot stack them.
        var deleteEnd = insertAt
        while deleteEnd < text.length {
            let next = text.lineRange(for: NSRange(location: deleteEnd, length: 0))
            let content = text.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines)
            guard content.isEmpty, NSMaxRange(next) > deleteEnd else { break }
            deleteEnd = NSMaxRange(next)
        }
        var deleteStart = insertAt
        while deleteStart > 0 {
            let previous = text.lineRange(for: NSRange(location: deleteStart - 1, length: 0))
            let content = text.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines)
            guard content.isEmpty else { break }
            deleteStart = previous.location
        }
        insertAt = deleteStart

        // insertAt normally lands on a line start, so a leading newline would
        // add a second blank line. Only needed when the document ends without
        // a trailing newline.
        let needsLeadingBreak = insertAt > 0 && text.character(at: insertAt - 1) != 0x0A
        let replacement = (needsLeadingBreak ? "\n" : "") + "\n---\n\n"
        let range = NSRange(location: insertAt, length: deleteEnd - insertAt)
        return TextEdit(
            range: range,
            replacement: replacement,
            selection: NSRange(
                location: insertAt + (replacement as NSString).length,
                length: 0
            )
        )
    }

    static func changeListIndent(
        by delta: Int,
        in text: NSString,
        selection: NSRange,
        indentUnit: String
    ) -> TextEdit? {
        guard delta != 0 else { return nil }
        return transformLines(in: text, selection: selection, requireChange: true) { lines in
            guard lines.contains(where: { isBulletItem($0) || isOrderedItem($0) }) else {
                return lines
            }
            var number = 0
            return lines.map { line in
                guard isBulletItem(line) || isOrderedItem(line) else { return line }
                let indent = leadingWhitespace(line)
                let body = String(line.dropFirst(indent.count))
                if delta > 0 {
                    return indent + indentUnit + body
                }
                guard indent.hasSuffix(indentUnit) else { return line }
                number += 1
                return String(indent.dropLast(indentUnit.count)) + body
            }
        }
    }

    // MARK: - Line plumbing

    /// Applies `body` to the whole lines touched by `selection`, declining when
    /// nothing changed so a shortcut on an ineligible line beeps instead of
    /// pushing an empty undo step.
    private static func transformLines(
        in text: NSString,
        selection: NSRange,
        requireChange: Bool = true,
        _ body: ([String]) -> [String]
    ) -> TextEdit? {
        guard text.length > 0 else { return nil }
        let location = min(max(selection.location, 0), max(0, text.length - 1))
        let clamped = NSRange(
            location: location,
            length: min(selection.length, text.length - location)
        )
        let block = text.lineRange(for: clamped)
        let source = text.substring(with: block)
        let hadTrailingNewline = source.hasSuffix("\n")
        var lines = source.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }

        var transformed = body(lines)
        guard !(requireChange && transformed == lines) else { return nil }
        if hadTrailingNewline { transformed.append("") }
        let replacement = transformed.joined(separator: "\n")

        return TextEdit(
            range: block,
            replacement: replacement,
            selection: NSRange(
                location: block.location,
                length: max(0, (replacement as NSString).length - (hadTrailingNewline ? 1 : 0))
            )
        )
    }

    private static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private static func splitQuotePrefix(_ line: String) -> (prefix: String, body: String) {
        var prefix = ""
        var rest = line
        while true {
            let trimmed = rest.drop { $0 == " " || $0 == "\t" }
            guard trimmed.first == ">" else { break }
            let consumed = rest.count - trimmed.count
            prefix += String(rest.prefix(consumed)) + ">"
            rest = String(trimmed.dropFirst())
            if rest.first == " " {
                prefix += " "
                rest.removeFirst()
            }
        }
        return (prefix, rest)
    }

    private static func headingLevel(of line: String) -> Int? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let hashes = trimmed.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let after = trimmed.dropFirst(hashes.count)
        guard after.first == " " else { return nil }
        return hashes.count
    }

    private static func stripHeadingMarker(_ line: String) -> String {
        guard let level = headingLevel(of: line) else { return line }
        let indent = leadingWhitespace(line)
        return String(line.dropFirst(indent.count + level + 1))
    }

    private static func listMarkerLength(_ line: String) -> Int {
        let characters = Array(line)
        guard !characters.isEmpty else { return 0 }
        if characters[0] == "-" || characters[0] == "*" || characters[0] == "+" {
            return characters.count > 1 && characters[1] == " " ? 2 : 0
        }
        var index = 0
        while index < characters.count, characters[index].isNumber { index += 1 }
        guard index > 0, index < characters.count,
              characters[index] == "." || characters[index] == ")",
              index + 1 < characters.count, characters[index + 1] == " "
        else { return 0 }
        return index + 2
    }

    private static func stripListMarker(_ line: String) -> String {
        let indent = leadingWhitespace(line)
        let rest = String(line.dropFirst(indent.count))
        let markerLength = listMarkerLength(rest)
        guard markerLength > 0 else { return line }
        var body = String(rest.dropFirst(markerLength))
        // A checkbox belongs to the marker, not the content.
        if body.count >= 4, body.hasPrefix("["), Array(body)[2] == "]" {
            let state = Array(body)[1]
            if state == " " || state == "x" || state == "X" {
                body = String(body.dropFirst(3))
                if body.hasPrefix(" ") { body.removeFirst() }
            }
        }
        return indent + body
    }

    private static func isBulletItem(_ line: String) -> Bool {
        let indent = leadingWhitespace(line)
        let rest = line.dropFirst(indent.count)
        guard let first = rest.first, first == "-" || first == "*" || first == "+" else { return false }
        return rest.dropFirst().first == " "
    }

    private static func isOrderedItem(_ line: String) -> Bool {
        let indent = leadingWhitespace(line)
        let rest = String(line.dropFirst(indent.count))
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let after = rest.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")" else { return false }
        return after.dropFirst().first == " "
    }

    /// nil when the line has no checkbox, otherwise whether it is checked.
    private static func taskState(of line: String) -> Bool? {
        let indent = leadingWhitespace(line)
        let rest = String(line.dropFirst(indent.count))
        let markerLength = listMarkerLength(rest)
        guard markerLength > 0 else { return nil }
        let body = Array(rest.dropFirst(markerLength))
        guard body.count >= 3, body[0] == "[", body[2] == "]" else { return nil }
        switch body[1] {
        case " ": return false
        case "x", "X": return true
        default: return nil
        }
    }

    private static func replacingTaskState(_ line: String, with state: String) -> String {
        let indent = leadingWhitespace(line)
        let rest = String(line.dropFirst(indent.count))
        let markerLength = listMarkerLength(rest)
        let marker = String(rest.prefix(markerLength))
        let body = String(rest.dropFirst(markerLength))
        let remainder = String(body.dropFirst(3))
        return indent + marker + "[" + state + "]" + remainder
    }
}
