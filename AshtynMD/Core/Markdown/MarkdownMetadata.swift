import Foundation

/// Everything the library index needs to know about a note, derived from its
/// text in a single pass.
///
/// This is the indexer's half of the shared Markdown parsing: it reuses the
/// same `MarkdownMaskIndex` and `MarkdownTagScanner` as the editor's styler, so
/// a tag that highlights while typing is exactly the tag that lands in the
/// sidebar.
struct ParsedNote: Sendable, Equatable {
    struct LinkHit: Sendable, Equatable, Hashable {
        /// Target text before any `|`, as written.
        let target: String
        /// Case-folded lookup key, matched against `files.title_key`.
        let key: String
        let alias: String?
        /// Full `[[...]]` span.
        let range: NSRange
        /// Just the text between the brackets.
        let innerRange: NSRange
    }

    var title: String = ""
    var titleKey: String = ""
    var titleRange: NSRange?
    var excerpt: String = ""
    var tags: [MarkdownTag] = []
    var links: [LinkHit] = []
    var todoTotal: Int = 0
    var todoOpen: Int = 0
    var wordCount: Int = 0
    var characterCount: Int = 0

    /// Minutes, rounded up, at 200 words per minute.
    var readingTimeMinutes: Int {
        guard wordCount > 0 else { return 0 }
        return max(1, Int(ceil(Double(wordCount) / 200.0)))
    }

    /// Tag rows to write, each tag plus every ancestor, deduplicated.
    func tagClosure() -> [MarkdownTag.ClosureEntry] {
        MarkdownTag.closure(for: tags)
    }
}

enum MarkdownMetadata {
    struct Options: Sendable, Equatable {
        var allowsClosingHashTags = true
        var excerptLimit = 200
        var titleLimit = 120
        static let `default` = Options()
    }

    /// Pure and allocation-light so it can run on the indexer actor during a
    /// full scan and on the main actor for live info-panel counts.
    static func parse(_ text: String, options: Options = .default) -> ParsedNote {
        let nsText = text as NSString
        let source = MarkdownSource(nsText)
        let mask = MarkdownMaskIndex.build(source: source, lines: 0..<source.lineCount)

        var note = ParsedNote()
        note.characterCount = text.count

        note.tags = MarkdownTagScanner.tags(
            source: source,
            mask: mask,
            lines: 0..<source.lineCount,
            options: MarkdownTagScanner.Options(
                allowsClosingHashTags: options.allowsClosingHashTags
            )
        )
        note.links = wikiLinks(source: source, mask: mask)

        let markers = MarkdownTasks.markers(in: text)
        note.todoTotal = markers.count
        note.todoOpen = markers.filter { !$0.isChecked }.count

        let bodyStart = firstContentLine(source: source, mask: mask)
        if let titleLine = bodyStart {
            note.titleRange = source.line(titleLine)
            note.title = title(
                source: source,
                mask: mask,
                line: titleLine,
                tags: note.tags,
                limit: options.titleLimit
            )
            note.titleKey = foldTitle(note.title)
            note.excerpt = excerpt(
                source: source,
                mask: mask,
                after: titleLine,
                limit: options.excerptLimit
            )
        }

        note.wordCount = wordCount(source: source, mask: mask)
        return note
    }

    static func foldTitle(_ title: String) -> String {
        title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    // MARK: - Title

    /// First line that is neither blank nor part of front matter.
    private static func firstContentLine(source: MarkdownSource, mask: MarkdownMaskIndex) -> Int? {
        for index in 0..<source.lineCount {
            if let frontMatter = mask.frontMatter,
               NSLocationInRange(source.line(index).location, frontMatter) {
                continue
            }
            if !isBlank(source: source, line: source.line(index)) { return index }
        }
        return nil
    }

    private static func title(
        source: MarkdownSource,
        mask: MarkdownMaskIndex,
        line index: Int,
        tags: [MarkdownTag],
        limit: Int
    ) -> String {
        let line = source.line(index)
        var content = stripBlockMarkers(source: source, line: line)

        // Leading tags are dropped so `#work meeting notes` titles — and so
        // names the file — as "meeting notes".
        let lineTags = tags.filter { NSIntersectionRange($0.range, line).length > 0 }
        var cursor = content.location
        var changed = true
        while changed {
            changed = false
            while cursor < NSMaxRange(content), source[cursor].isMarkdownWhitespace { cursor += 1 }
            if let tag = lineTags.first(where: { $0.range.location == cursor }) {
                cursor = NSMaxRange(tag.range)
                changed = true
            }
        }
        if cursor > content.location, cursor <= NSMaxRange(content) {
            content = NSRange(location: cursor, length: NSMaxRange(content) - cursor)
        }

        let flattened = flattenInline(source: source, mask: mask, range: content)
        return clamp(collapseWhitespace(flattened), to: limit)
    }

    // MARK: - Excerpt

    private static func excerpt(
        source: MarkdownSource,
        mask: MarkdownMaskIndex,
        after titleLine: Int,
        limit: Int
    ) -> String {
        var pieces: [String] = []
        var length = 0

        for index in (titleLine + 1)..<source.lineCount {
            if mask.maskedLines.contains(index) { continue }
            let line = source.line(index)
            if isBlank(source: source, line: line) { continue }

            let content = stripBlockMarkers(source: source, line: line)
            guard content.length > 0 else { continue }
            if isPureTagLine(source: source, mask: mask, range: content) { continue }

            let flattened = collapseWhitespace(
                flattenInline(source: source, mask: mask, range: content)
            )
            guard !flattened.isEmpty else { continue }
            pieces.append(flattened)
            length += flattened.count + 1
            if length >= limit { break }
        }

        return clamp(pieces.joined(separator: " "), to: limit)
    }

    private static func isPureTagLine(
        source: MarkdownSource,
        mask: MarkdownMaskIndex,
        range: NSRange
    ) -> Bool {
        let lineIndex = source.lineIndex(containing: range.location)
        let tags = MarkdownTagScanner.tags(
            source: source,
            mask: mask,
            lines: lineIndex..<(lineIndex + 1)
        )
        guard !tags.isEmpty else { return false }
        var cursor = range.location
        for tag in tags where tag.range.location >= cursor {
            while cursor < NSMaxRange(range), source[cursor].isMarkdownWhitespace { cursor += 1 }
            guard tag.range.location == cursor else { return false }
            cursor = NSMaxRange(tag.range)
        }
        while cursor < NSMaxRange(range), source[cursor].isMarkdownWhitespace { cursor += 1 }
        return cursor >= NSMaxRange(range)
    }

    // MARK: - Text shaping

    /// Removes heading hashes, quote markers, and list/task markers, returning
    /// the content range of the line.
    private static func stripBlockMarkers(source: MarkdownSource, line: NSRange) -> NSRange {
        var cursor = line.location
        let end = NSMaxRange(line)

        var progressed = true
        while progressed {
            progressed = false
            while cursor < end, source[cursor].isMarkdownWhitespace { cursor += 1 }
            guard cursor < end else { break }

            if source[cursor] == 0x3E {  // >
                cursor += 1
                progressed = true
                continue
            }
            if source[cursor] == 0x23 {  // #
                var probe = cursor
                while probe < end, source[probe] == 0x23 { probe += 1 }
                if probe - cursor <= 6, probe < end, source[probe].isMarkdownWhitespace {
                    cursor = probe + 1
                    progressed = true
                    continue
                }
            }
            if source[cursor] == 0x2D || source[cursor] == 0x2A || source[cursor] == 0x2B {
                if cursor + 1 < end, source[cursor + 1].isMarkdownWhitespace {
                    cursor += 2
                    progressed = true
                    continue
                }
            }
            if source[cursor].isMarkdownDigit {
                var probe = cursor
                while probe < end, source[probe].isMarkdownDigit { probe += 1 }
                if probe < end, source[probe] == 0x2E || source[probe] == 0x29,
                   probe + 1 < end, source[probe + 1].isMarkdownWhitespace {
                    cursor = probe + 2
                    progressed = true
                    continue
                }
            }
            // Task checkbox, once a list marker has been consumed.
            if source[cursor] == 0x5B, cursor + 2 < end, source[cursor + 2] == 0x5D {
                let state = source[cursor + 1]
                if state == 0x20 || state == 0x78 || state == 0x58 {
                    cursor += 3
                    progressed = true
                    continue
                }
            }
        }

        while cursor < end, source[cursor].isMarkdownWhitespace { cursor += 1 }
        return NSRange(location: cursor, length: max(0, end - cursor))
    }

    /// Drops inline markup so a title reads as prose: `**bold**` becomes bold,
    /// `[text](url)` becomes text, `[[Note]]` becomes Note.
    private static func flattenInline(
        source: MarkdownSource,
        mask: MarkdownMaskIndex,
        range: NSRange
    ) -> String {
        guard range.length > 0 else { return "" }

        // Ranges to drop entirely (delimiters and link destinations) and
        // ranges to keep verbatim are decided up front so one left-to-right
        // pass can emit the result.
        var dropped: [NSRange] = []
        for link in mask.links where NSIntersectionRange(link.full, range).length > 0 {
            switch link.kind {
            case .inline, .image:
                dropped.append(contentsOf: link.markers)
                if let destination = link.destination { dropped.append(destination) }
            case .wiki:
                dropped.append(contentsOf: link.markers)
                // Keep only the visible half of `[[Target|Alias]]`.
                if let text = link.text,
                   let pipe = firstIndex(of: 0x7C, source: source, in: text) {
                    dropped.append(NSRange(location: pipe, length: NSMaxRange(text) - pipe))
                }
            case .autolink:
                dropped.append(contentsOf: link.markers)
            }
        }
        for code in mask.inlineCode where NSIntersectionRange(code.full, range).length > 0 {
            dropped.append(code.openDelimiter)
            dropped.append(code.closeDelimiter)
        }
        for comment in mask.comments where NSIntersectionRange(comment, range).length > 0 {
            dropped.append(comment)
        }

        var units: [unichar] = []
        var index = range.location
        let end = NSMaxRange(range)

        while index < end {
            if let drop = dropped.first(where: { NSLocationInRange(index, $0) }) {
                index = NSMaxRange(drop)
                continue
            }
            let character = source[index]
            // Emphasis and strikethrough delimiters are plain runs; drop them.
            if character == 0x2A || character == 0x5F || character == 0x7E {
                let probe = NSRange(location: index, length: 1)
                if !mask.isMasked(probe) {
                    index += 1
                    continue
                }
            }
            if character == 0x5C, index + 1 < end, source[index + 1].isMarkdownASCIIPunctuation {
                units.append(source[index + 1])
                index += 2
                continue
            }
            units.append(character)
            index += 1
        }

        return String(utf16CodeUnits: units, count: units.count)
    }

    private static func firstIndex(
        of character: unichar,
        source: MarkdownSource,
        in range: NSRange
    ) -> Int? {
        for index in range.location..<NSMaxRange(range) where source[index] == character {
            return index
        }
        return nil
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func clamp(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    private static func isBlank(source: MarkdownSource, line: NSRange) -> Bool {
        for index in line.location..<NSMaxRange(line) where !source[index].isMarkdownWhitespace {
            return false
        }
        return true
    }

    // MARK: - Counts

    private static func wikiLinks(
        source: MarkdownSource,
        mask: MarkdownMaskIndex
    ) -> [ParsedNote.LinkHit] {
        mask.links.compactMap { link in
            guard link.kind == .wiki, let inner = link.text, inner.length > 0 else { return nil }
            let raw = source.string(in: inner)
            let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = parts.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !target.isEmpty else { return nil }
            let alias = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: .whitespaces)
                : nil
            return ParsedNote.LinkHit(
                target: target,
                key: foldTitle(target),
                alias: (alias?.isEmpty ?? true) ? nil : alias,
                range: link.full,
                innerRange: inner
            )
        }
    }

    /// Whitespace-delimited runs, plus one word per CJK ideograph so notes
    /// written in Chinese, Japanese, or Korean do not report a single word.
    /// Code is included, matching Bear.
    private static func wordCount(source: MarkdownSource, mask: MarkdownMaskIndex) -> Int {
        var count = 0
        var inWord = false

        for lineIndex in 0..<source.lineCount {
            if let frontMatter = mask.frontMatter,
               NSLocationInRange(source.line(lineIndex).location, frontMatter) {
                continue
            }
            if mask.fences.contains(where: { fence in
                (fence.openMarker.length > 0
                    && source.lineIndex(containing: fence.openMarker.location) == lineIndex)
                    || (fence.closeMarker.map {
                        source.lineIndex(containing: $0.location) == lineIndex
                    } ?? false)
            }) {
                continue
            }

            let line = source.line(lineIndex)
            inWord = false
            for index in line.location..<NSMaxRange(line) {
                let character = source[index]
                if isCJK(character) {
                    count += 1
                    inWord = false
                    continue
                }
                if character.isMarkdownWhitespace {
                    inWord = false
                } else if !inWord {
                    inWord = true
                    count += 1
                }
            }
        }
        return count
    }

    private static func isCJK(_ character: unichar) -> Bool {
        switch character {
        case 0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // Compatibility Ideographs
             0x3040...0x30FF,   // Hiragana + Katakana
             0xAC00...0xD7AF:   // Hangul syllables
            return true
        default:
            return false
        }
    }
}
