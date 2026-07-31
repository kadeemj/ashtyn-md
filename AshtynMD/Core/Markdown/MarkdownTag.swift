import Foundation

/// An inline `#tag` written in a note's body.
///
/// Tags are content, not metadata: they live in the text the user typed, so
/// the note file stays the source of truth and the index can always be rebuilt
/// from it.
struct MarkdownTag: Sendable, Equatable, Hashable {
    /// Full span including the leading `#` and, for the multi-word form, the
    /// closing `#`.
    let range: NSRange
    /// The path as written, e.g. `Work/Alpha`.
    let path: String
    /// Case-folded lookup key, e.g. `work/alpha`.
    let key: String
    let isClosingHashForm: Bool

    var components: [String] {
        path.split(separator: "/").map(String.init)
    }

    var depth: Int { components.count }

    /// One entry per tag and every ancestor of it, deduplicated.
    ///
    /// This is exactly the closure the indexer writes into `file_tags`: storing
    /// ancestors turns "notes tagged #work, including descendants" into a plain
    /// equality join instead of a recursive query.
    struct ClosureEntry: Sendable, Equatable, Hashable {
        let key: String
        let displayPath: String
        /// True when the tag was written out in full, false when it is only
        /// present as an ancestor of a deeper tag.
        let isDirect: Bool
    }

    static func closure(for tags: [MarkdownTag]) -> [ClosureEntry] {
        var order: [String] = []
        var entries: [String: ClosureEntry] = [:]

        for tag in tags {
            let components = tag.components
            guard !components.isEmpty else { continue }
            for depth in 1...components.count {
                let displayPath = components[0..<depth].joined(separator: "/")
                let key = fold(displayPath)
                let isDirect = depth == components.count
                if let existing = entries[key] {
                    entries[key] = ClosureEntry(
                        key: key,
                        // The deepest write wins the display casing, matching
                        // "most recently indexed casing" in the tags table.
                        displayPath: isDirect || existing.isDirect ? (isDirect ? displayPath : existing.displayPath) : displayPath,
                        isDirect: existing.isDirect || isDirect
                    )
                } else {
                    order.append(key)
                    entries[key] = ClosureEntry(key: key, displayPath: displayPath, isDirect: isDirect)
                }
            }
        }
        return order.compactMap { entries[$0] }
    }

    static func fold(_ path: String) -> String {
        path.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }
}

/// The one place tag grammar is defined.
///
/// Both the editor styler and the library indexer route through here, so a
/// `#tag` that highlights in the editor is always the same `#tag` that shows
/// up in the sidebar.
enum MarkdownTagScanner {
    struct Options: Sendable, Equatable {
        /// Bear's `#multi word tag#` form.
        var allowsClosingHashTags = true
        /// Upper bound on a multi-word tag, in UTF-16 units.
        var closingHashLimit = 100
        static let `default` = Options()
    }

    static func tags(in text: NSString, options: Options = .default) -> [MarkdownTag] {
        let source = MarkdownSource(text)
        let mask = MarkdownMaskIndex.build(source: source, lines: 0..<source.lineCount)
        return tags(source: source, mask: mask, lines: 0..<source.lineCount, options: options)
    }

    static func tags(
        source: MarkdownSource,
        mask: MarkdownMaskIndex,
        lines: Range<Int>,
        options: Options = .default
    ) -> [MarkdownTag] {
        var found: [MarkdownTag] = []
        for lineIndex in lines where !mask.maskedLines.contains(lineIndex) {
            scanLine(source: source, mask: mask, line: source.line(lineIndex), options: options, into: &found)
        }
        return found
    }

    // MARK: - Line scanning

    private static func scanLine(
        source: MarkdownSource,
        mask: MarkdownMaskIndex,
        line: NSRange,
        options: Options,
        into found: inout [MarkdownTag]
    ) {
        var index = line.location
        let end = NSMaxRange(line)

        while index < end {
            guard source[index] == 0x23 else {
                index += 1
                continue
            }
            guard canOpenTag(source: source, at: index, lineStart: line.location) else {
                index += 1
                continue
            }
            guard let tag = parseTag(
                source: source,
                mask: mask,
                from: index,
                lineEnd: end,
                options: options
            ) else {
                index += 1
                continue
            }
            if mask.isMasked(tag.range) {
                index = NSMaxRange(tag.range)
                continue
            }
            found.append(tag)
            index = NSMaxRange(tag.range)
        }
    }

    /// A `#` may start a tag at the start of the text, after whitespace, or
    /// after an opening bracket or quote — never mid-word, which is what keeps
    /// `C#`, `issue#12`, and `https://x/y#frag` from becoming tags.
    private static func canOpenTag(source: MarkdownSource, at index: Int, lineStart: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = source[index - 1]
        if previous == 0x5C { return false }
        if index == lineStart { return true }
        if previous.isMarkdownWhitespace || previous.isMarkdownLineBreak { return true }
        switch previous {
        case 0x28, 0x5B, 0x7B, 0x22, 0x27: return true
        default: return false
        }
    }

    private static func parseTag(
        source: MarkdownSource,
        mask: MarkdownMaskIndex,
        from hashIndex: Int,
        lineEnd: Int,
        options: Options
    ) -> MarkdownTag? {
        let bodyStart = hashIndex + 1
        guard bodyStart < lineEnd, isSegmentStart(source[bodyStart]) else { return nil }

        var cursor = bodyStart
        while cursor < lineEnd, isSegmentCharacter(source[cursor]) || source[cursor] == 0x2F {
            cursor += 1
        }
        var bodyEnd = cursor
        // Trim trailing punctuation and separators, e.g. `#work.` and `#work/`.
        while bodyEnd > bodyStart, isTrailingPunctuation(source[bodyEnd - 1]) {
            bodyEnd -= 1
        }
        guard bodyEnd > bodyStart else { return nil }

        if options.allowsClosingHashTags,
           let multiWord = parseClosingHashForm(
               source: source,
               hashIndex: hashIndex,
               plainEnd: bodyEnd,
               lineEnd: lineEnd,
               options: options
           ) {
            return multiWord
        }

        let path = source.string(in: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
        let key = MarkdownTag.fold(path)
        guard isAcceptable(key) else { return nil }
        return MarkdownTag(
            range: NSRange(location: hashIndex, length: bodyEnd - hashIndex),
            path: path,
            key: key,
            isClosingHashForm: false
        )
    }

    /// `#multi word tag#`.
    ///
    /// The span must contain a space. Without that constraint `#a#b` would
    /// parse as one strange tag instead of two plain ones that the ordinary
    /// scanner rejects, and every `#` pair in prose would become a false hit.
    private static func parseClosingHashForm(
        source: MarkdownSource,
        hashIndex: Int,
        plainEnd: Int,
        lineEnd: Int,
        options: Options
    ) -> MarkdownTag? {
        guard plainEnd < lineEnd, source[plainEnd].isMarkdownWhitespace else { return nil }

        let limit = min(lineEnd, hashIndex + options.closingHashLimit)
        var cursor = plainEnd
        var closing: Int?
        while cursor < limit {
            let character = source[cursor]
            if character == 0x23 {
                closing = cursor
                break
            }
            if character.isMarkdownLineBreak { return nil }
            cursor += 1
        }
        guard let closing else { return nil }

        let bodyStart = hashIndex + 1
        let bodyLength = closing - bodyStart
        guard bodyLength > 0 else { return nil }
        guard !source[bodyStart].isMarkdownWhitespace,
              !source[closing - 1].isMarkdownWhitespace else { return nil }

        var sawSpace = false
        for offset in bodyStart..<closing {
            let character = source[offset]
            if character == 0x23 { return nil }
            if character.isMarkdownWhitespace { sawSpace = true }
        }
        guard sawSpace else { return nil }

        if closing + 1 < lineEnd, source[closing + 1].isMarkdownWordCharacter { return nil }

        let path = source.string(in: NSRange(location: bodyStart, length: bodyLength))
        let key = MarkdownTag.fold(path)
        guard isAcceptable(key) else { return nil }
        return MarkdownTag(
            range: NSRange(location: hashIndex, length: closing + 1 - hashIndex),
            path: path,
            key: key,
            isClosingHashForm: true
        )
    }

    // MARK: - Character rules

    /// The character right after `#`. Requiring a word character here is what
    /// makes `# Heading` a heading and `#tag` a tag.
    private static func isSegmentStart(_ character: unichar) -> Bool {
        character.isMarkdownWordCharacter
    }

    private static func isSegmentCharacter(_ character: unichar) -> Bool {
        if character.isMarkdownWordCharacter { return true }
        switch character {
        case 0x2D, 0x2B, 0x2E: return true  // - + .
        default: return false
        }
    }

    private static func isTrailingPunctuation(_ character: unichar) -> Bool {
        switch character {
        case 0x2E, 0x2C, 0x3B, 0x3A, 0x21, 0x3F, 0x29, 0x5D, 0x7D, 0x22, 0x27, 0x2F, 0x2D, 0x2B:
            return true
        default:
            return false
        }
    }

    /// Rejects the all-digit case so issue references like `#12345` stay prose.
    private static func isAcceptable(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return key.contains { !$0.isNumber && $0 != "/" }
    }
}
