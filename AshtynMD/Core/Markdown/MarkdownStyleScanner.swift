import Foundation

/// Turns Markdown source into styled runs and per-line block structure.
///
/// Written by hand rather than driven from tree-sitter or swift-markdown
/// because the editor needs *structure* those give up: heading level, list and
/// quote depth, the exact sub-ranges of markers so they can be dimmed, and tag
/// ranges, which neither grammar models at all. Being a line-oriented scan also
/// makes it incremental for free — restyling one edited block never rescans the
/// document.
enum MarkdownStyleScanner {
    static func scan(_ text: NSString) -> MarkdownStyleResult {
        let source = MarkdownSource(text)
        return scan(source: source, lines: 0..<source.lineCount, fenceState: false, detectFrontMatter: true)
    }

    /// Scans only the lines touched by `range`. `fenceState` says whether the
    /// first of those lines already sits inside a fenced code block; get it
    /// from `fenceState(of:atLineStartingAt:)`.
    static func scan(
        _ text: NSString,
        in range: NSRange,
        fenceState: Bool
    ) -> MarkdownStyleResult {
        let source = MarkdownSource(text)
        let lines = source.lineIndices(intersecting: range)
        return scan(
            source: source,
            lines: lines,
            fenceState: fenceState,
            detectFrontMatter: lines.lowerBound == 0
        )
    }

    /// Whether the line beginning at `location` starts inside a fenced code
    /// block. Cheap enough to call per restyle: it only reads fence lines.
    static func fenceState(of text: NSString, atLineStartingAt location: Int) -> Bool {
        let source = MarkdownSource(text)
        let target = source.lineIndex(containing: location)
        guard target > 0 else { return false }
        let mask = MarkdownMaskIndex.build(source: source, lines: 0..<target)
        return mask.endsInsideFence
    }

    // MARK: - Core

    static func scan(
        source: MarkdownSource,
        lines: Range<Int>,
        fenceState: Bool,
        detectFrontMatter: Bool
    ) -> MarkdownStyleResult {
        var result = MarkdownStyleResult()
        guard !lines.isEmpty else { return result }

        let mask = MarkdownMaskIndex.build(
            source: source,
            lines: lines,
            fenceState: fenceState,
            detectFrontMatter: detectFrontMatter
        )

        if let frontMatter = mask.frontMatter {
            result.spans.append(MarkdownStyleSpan(range: frontMatter, role: .frontMatter))
        }

        // Fence markers and info strings come from the mask, which already
        // resolved which lines are code.
        var fenceMarkers: [Int: NSRange] = [:]
        for fence in mask.fences {
            if fence.openMarker.length > 0 {
                result.spans.append(MarkdownStyleSpan(range: fence.openMarker, role: .codeFence))
                fenceMarkers[source.lineIndex(containing: fence.openMarker.location)] = fence.openMarker
            }
            if let info = fence.infoString {
                result.spans.append(MarkdownStyleSpan(range: info, role: .codeInfoString))
            }
            if let close = fence.closeMarker {
                result.spans.append(MarkdownStyleSpan(range: close, role: .codeFence))
                fenceMarkers[source.lineIndex(containing: close.location)] = close
            }
        }

        for lineIndex in lines {
            let line = source.line(lineIndex)

            if let frontMatter = mask.frontMatter,
               NSIntersectionRange(frontMatter, line).length > 0 || line.length == 0 &&
               NSLocationInRange(line.location, frontMatter) {
                result.blocks.append(
                    MarkdownBlockStyle(lineRange: line, kind: .frontMatter, contentColumn: 0)
                )
                continue
            }

            if mask.maskedLines.contains(lineIndex) {
                // Inside a fence. Emit the code body per line so a ranged
                // rescan of one line reproduces the same spans as a full scan.
                if fenceMarkers[lineIndex] == nil, line.length > 0 {
                    result.spans.append(MarkdownStyleSpan(range: line, role: .codeBlock))
                }
                result.blocks.append(
                    MarkdownBlockStyle(lineRange: line, kind: .codeBlock, contentColumn: 0)
                )
                continue
            }

            scanLine(
                source: source,
                mask: mask,
                lineIndex: lineIndex,
                lines: lines,
                into: &result
            )
        }

        result.spans.sort {
            $0.range.location == $1.range.location
                ? $0.range.length > $1.range.length
                : $0.range.location < $1.range.location
        }
        return result
    }

    // MARK: - Block structure

    private static func scanLine(
        source: MarkdownSource,
        mask: MarkdownMaskIndex,
        lineIndex: Int,
        lines: Range<Int>,
        into result: inout MarkdownStyleResult
    ) {
        let line = source.line(lineIndex)
        guard line.length > 0 else {
            result.blocks.append(MarkdownBlockStyle(lineRange: line, kind: .blank, contentColumn: 0))
            return
        }

        var cursor = line.location
        let end = NSMaxRange(line)

        // Blockquote markers, possibly nested.
        var quoteDepth = 0
        var scanning = true
        while scanning {
            var probe = cursor
            var indent = 0
            while probe < end, source[probe].isMarkdownWhitespace, indent < 4 {
                probe += 1
                indent += 1
            }
            if probe < end, source[probe] == 0x3E {
                quoteDepth += 1
                var markerEnd = probe + 1
                if markerEnd < end, source[markerEnd].isMarkdownWhitespace { markerEnd += 1 }
                result.spans.append(
                    MarkdownStyleSpan(
                        range: NSRange(location: probe, length: markerEnd - probe),
                        role: .blockQuoteMarker,
                        level: quoteDepth
                    )
                )
                cursor = markerEnd
            } else {
                scanning = false
            }
        }

        var indent = 0
        var contentStart = cursor
        while contentStart < end, source[contentStart].isMarkdownWhitespace {
            contentStart += 1
            indent += 1
        }

        // Setext heading underline: only when the previous line is prose.
        if quoteDepth == 0,
           let level = setextLevel(source: source, line: line, contentStart: contentStart, end: end),
           lineIndex > 0,
           lines.contains(lineIndex - 1),
           isSetextCandidate(source: source, mask: mask, lineIndex: lineIndex - 1) {
            result.spans.append(MarkdownStyleSpan(range: line, role: .headingMarker, level: level))
            result.blocks.append(
                MarkdownBlockStyle(lineRange: line, kind: .heading(level), contentColumn: 0)
            )
            // Retroactively promote the text line above.
            if let existing = result.blocks.lastIndex(where: { $0.lineRange == source.line(lineIndex - 1) }) {
                let previous = result.blocks[existing]
                result.blocks[existing] = MarkdownBlockStyle(
                    lineRange: previous.lineRange,
                    kind: .heading(level),
                    contentColumn: previous.contentColumn
                )
                result.spans.append(
                    MarkdownStyleSpan(range: previous.lineRange, role: .heading, level: level)
                )
            }
            return
        }

        // Thematic break.
        if isThematicBreak(source: source, from: contentStart, to: end) {
            result.spans.append(MarkdownStyleSpan(range: line, role: .thematicBreak))
            result.blocks.append(
                MarkdownBlockStyle(lineRange: line, kind: .thematicBreak, contentColumn: 0)
            )
            return
        }

        // ATX heading.
        if indent < 4, contentStart < end, source[contentStart] == 0x23 {
            var hashEnd = contentStart
            while hashEnd < end, source[hashEnd] == 0x23 { hashEnd += 1 }
            let level = hashEnd - contentStart
            if level <= 6, hashEnd < end, source[hashEnd].isMarkdownWhitespace {
                var textStart = hashEnd
                while textStart < end, source[textStart].isMarkdownWhitespace { textStart += 1 }
                result.spans.append(
                    MarkdownStyleSpan(
                        range: NSRange(location: contentStart, length: textStart - contentStart),
                        role: .headingMarker,
                        level: level
                    )
                )
                if textStart < end {
                    result.spans.append(
                        MarkdownStyleSpan(
                            range: NSRange(location: textStart, length: end - textStart),
                            role: .heading,
                            level: level
                        )
                    )
                }
                result.blocks.append(
                    MarkdownBlockStyle(
                        lineRange: line,
                        kind: .heading(level),
                        contentColumn: textStart - line.location
                    )
                )
                scanInline(source: source, mask: mask, range: NSRange(location: textStart, length: end - textStart), into: &result)
                return
            }
        }

        // List item, optionally a task.
        if let marker = listMarker(source: source, from: contentStart, to: end) {
            result.spans.append(MarkdownStyleSpan(range: marker.range, role: .listMarker))
            var contentColumn = NSMaxRange(marker.range) - line.location
            var isTask = false
            if let task = taskMarker(source: source, from: NSMaxRange(marker.range), to: end) {
                isTask = true
                result.spans.append(
                    MarkdownStyleSpan(
                        range: task.range,
                        role: task.isChecked ? .taskMarkerChecked : .taskMarkerUnchecked
                    )
                )
                result.taskBracketRanges.append(task.range)
                var afterTask = NSMaxRange(task.range)
                while afterTask < end, source[afterTask].isMarkdownWhitespace { afterTask += 1 }
                contentColumn = afterTask - line.location
            }
            result.blocks.append(
                MarkdownBlockStyle(
                    lineRange: line,
                    kind: .listItem(depth: indent / 2, ordered: marker.ordered, task: isTask),
                    contentColumn: contentColumn
                )
            )
            scanInline(
                source: source,
                mask: mask,
                range: NSRange(location: line.location + contentColumn, length: end - line.location - contentColumn),
                into: &result
            )
            return
        }

        let kind: MarkdownBlockKind = quoteDepth > 0 ? .blockQuote(depth: quoteDepth) : .paragraph
        if quoteDepth > 0, contentStart < end {
            result.spans.append(
                MarkdownStyleSpan(
                    range: NSRange(location: contentStart, length: end - contentStart),
                    role: .blockQuote,
                    level: quoteDepth
                )
            )
        }
        result.blocks.append(
            MarkdownBlockStyle(
                lineRange: line,
                kind: kind,
                contentColumn: contentStart - line.location
            )
        )
        scanInline(
            source: source,
            mask: mask,
            range: NSRange(location: contentStart, length: end - contentStart),
            into: &result
        )
    }

    // MARK: - Inline

    private static func scanInline(
        source: MarkdownSource,
        mask: MarkdownMaskIndex,
        range: NSRange,
        into result: inout MarkdownStyleResult
    ) {
        guard range.length > 0 else { return }

        for escape in mask.escapes where NSIntersectionRange(escape, range).length > 0 {
            result.spans.append(MarkdownStyleSpan(range: escape, role: .escape))
        }

        for code in mask.inlineCode where NSIntersectionRange(code.full, range).length > 0 {
            result.spans.append(MarkdownStyleSpan(range: code.openDelimiter, role: .inlineCodeMarker))
            if code.content.length > 0 {
                result.spans.append(MarkdownStyleSpan(range: code.content, role: .inlineCode))
            }
            result.spans.append(MarkdownStyleSpan(range: code.closeDelimiter, role: .inlineCodeMarker))
        }

        for comment in mask.comments where NSIntersectionRange(comment, range).length > 0 {
            result.spans.append(MarkdownStyleSpan(range: comment, role: .inlineCode))
        }

        for link in mask.links where NSIntersectionRange(link.full, range).length > 0 {
            switch link.kind {
            case .autolink:
                result.spans.append(MarkdownStyleSpan(range: link.markers[0], role: .linkMarker))
                result.spans.append(MarkdownStyleSpan(range: link.markers[1], role: .linkMarker))
                if let destination = link.destination {
                    result.spans.append(MarkdownStyleSpan(range: destination, role: .autolink))
                }
            case .wiki:
                for marker in link.markers {
                    result.spans.append(MarkdownStyleSpan(range: marker, role: .wikiLinkMarker))
                }
                if let text = link.text {
                    result.spans.append(MarkdownStyleSpan(range: text, role: .wikiLink))
                }
            case .inline, .image:
                for (offset, marker) in link.markers.enumerated() {
                    let role: MarkdownStyleRole =
                        (link.kind == .image && offset == 0) ? .imageMarker : .linkMarker
                    result.spans.append(MarkdownStyleSpan(range: marker, role: role))
                }
                if let text = link.text, text.length > 0 {
                    result.spans.append(MarkdownStyleSpan(range: text, role: .linkText))
                }
                if let destination = link.destination, destination.length > 0 {
                    result.spans.append(MarkdownStyleSpan(range: destination, role: .linkURL))
                }
            }
        }

        scanEmphasis(source: source, mask: mask, range: range, into: &result)

        var tags: [MarkdownTag] = []
        let line = source.line(source.lineIndex(containing: range.location))
        if !mask.maskedLines.contains(source.lineIndex(containing: range.location)) {
            var scratch: [MarkdownTag] = []
            collectTags(source: source, mask: mask, line: line, into: &scratch)
            tags = scratch.filter { NSIntersectionRange($0.range, range).length > 0 }
        }
        for tag in tags {
            result.spans.append(MarkdownStyleSpan(range: tag.range, role: .tag, level: tag.depth))
            result.tagRanges.append(tag.range)
        }
    }

    private static func collectTags(
        source: MarkdownSource,
        mask: MarkdownMaskIndex,
        line: NSRange,
        into found: inout [MarkdownTag]
    ) {
        let lineIndex = source.lineIndex(containing: line.location)
        found = MarkdownTagScanner.tags(
            source: source,
            mask: mask,
            lines: lineIndex..<(lineIndex + 1)
        )
    }

    /// Delimiter-run emphasis, restricted to a single line.
    ///
    /// CommonMark allows emphasis to wrap across lines inside a paragraph, but
    /// keeping it line-local is what makes a one-line restyle correct without
    /// rescanning neighbours — and it still rejects the case that actually
    /// matters, a run straddling a blank line.
    private static func scanEmphasis(
        source: MarkdownSource,
        mask: MarkdownMaskIndex,
        range: NSRange,
        into result: inout MarkdownStyleResult
    ) {
        struct Delimiter {
            let range: NSRange
            let character: unichar
            let canOpen: Bool
            let canClose: Bool
        }

        var delimiters: [Delimiter] = []
        var index = range.location
        let end = NSMaxRange(range)

        while index < end {
            let character = source[index]
            guard character == 0x2A || character == 0x5F || character == 0x7E else {
                index += 1
                continue
            }
            let probe = NSRange(location: index, length: 1)
            if mask.isMasked(probe) {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < end, source[runEnd] == character { runEnd += 1 }
            let runRange = NSRange(location: index, length: runEnd - index)

            let before = index > 0 ? source[index - 1] : 0x20
            let after = runEnd < source.length ? source[runEnd] : 0x20
            let followedByText = !after.isMarkdownWhitespace && !after.isMarkdownLineBreak
            let precededByText = !before.isMarkdownWhitespace && !before.isMarkdownLineBreak

            var canOpen = followedByText
            var canClose = precededByText
            if character == 0x5F {
                // Underscore never works intraword, which is what keeps
                // snake_case_names intact.
                if before.isMarkdownWordCharacter { canOpen = false }
                if after.isMarkdownWordCharacter { canClose = false }
            }
            if character == 0x7E, runRange.length != 2 {
                index = runEnd
                continue
            }

            delimiters.append(
                Delimiter(range: runRange, character: character, canOpen: canOpen, canClose: canClose)
            )
            index = runEnd
        }

        var openStack: [Int] = []
        var consumed = Set<Int>()

        for (position, delimiter) in delimiters.enumerated() {
            if delimiter.canClose,
               let match = openStack.last(where: {
                   !consumed.contains($0)
                       && delimiters[$0].character == delimiter.character
                       && delimiters[$0].canOpen
               }) {
                consumed.insert(match)
                consumed.insert(position)
                openStack.removeAll { $0 == match }

                let opener = delimiters[match]
                let width = min(opener.range.length, delimiter.range.length)
                let role: MarkdownStyleRole
                if delimiter.character == 0x7E {
                    role = .strikethrough
                } else if width >= 3 {
                    role = .boldItalic
                } else if width == 2 {
                    role = .bold
                } else {
                    role = .italic
                }
                let openMarker = NSRange(
                    location: NSMaxRange(opener.range) - width,
                    length: width
                )
                let closeMarker = NSRange(location: delimiter.range.location, length: width)
                let contentStart = NSMaxRange(openMarker)
                let contentLength = closeMarker.location - contentStart
                guard contentLength > 0 else { continue }
                result.spans.append(MarkdownStyleSpan(range: openMarker, role: .emphasisMarker))
                result.spans.append(
                    MarkdownStyleSpan(
                        range: NSRange(location: contentStart, length: contentLength),
                        role: role
                    )
                )
                result.spans.append(MarkdownStyleSpan(range: closeMarker, role: .emphasisMarker))
                continue
            }
            if delimiter.canOpen { openStack.append(position) }
        }
    }

    // MARK: - Line predicates

    private static func setextLevel(
        source: MarkdownSource,
        line: NSRange,
        contentStart: Int,
        end: Int
    ) -> Int? {
        guard contentStart < end else { return nil }
        let character = source[contentStart]
        guard character == 0x3D || character == 0x2D else { return nil }
        var cursor = contentStart
        while cursor < end, source[cursor] == character { cursor += 1 }
        guard cursor - contentStart >= 2 else { return nil }
        while cursor < end {
            guard source[cursor].isMarkdownWhitespace else { return nil }
            cursor += 1
        }
        return character == 0x3D ? 1 : 2
    }

    private static func isSetextCandidate(
        source: MarkdownSource,
        mask: MarkdownMaskIndex,
        lineIndex: Int
    ) -> Bool {
        guard !mask.maskedLines.contains(lineIndex) else { return false }
        let line = source.line(lineIndex)
        guard line.length > 0 else { return false }
        var cursor = line.location
        while cursor < NSMaxRange(line), source[cursor].isMarkdownWhitespace { cursor += 1 }
        guard cursor < NSMaxRange(line) else { return false }
        // A marker line cannot be the text half of a setext heading.
        switch source[cursor] {
        case 0x23, 0x3E, 0x2D, 0x2A, 0x2B: return false
        default: return true
        }
    }

    private static func isThematicBreak(source: MarkdownSource, from start: Int, to end: Int) -> Bool {
        guard start < end else { return false }
        let character = source[start]
        guard character == 0x2D || character == 0x2A || character == 0x5F else { return false }
        var count = 0
        var cursor = start
        while cursor < end {
            let current = source[cursor]
            if current == character {
                count += 1
            } else if !current.isMarkdownWhitespace {
                return false
            }
            cursor += 1
        }
        return count >= 3
    }

    private static func listMarker(
        source: MarkdownSource,
        from start: Int,
        to end: Int
    ) -> (range: NSRange, ordered: Bool)? {
        guard start < end else { return nil }
        let character = source[start]
        if character == 0x2D || character == 0x2A || character == 0x2B {
            guard start + 1 < end, source[start + 1].isMarkdownWhitespace else { return nil }
            return (NSRange(location: start, length: 2), false)
        }
        guard character.isMarkdownDigit else { return nil }
        var cursor = start
        while cursor < end, source[cursor].isMarkdownDigit { cursor += 1 }
        guard cursor < end, source[cursor] == 0x2E || source[cursor] == 0x29 else { return nil }
        guard cursor + 1 < end, source[cursor + 1].isMarkdownWhitespace else { return nil }
        return (NSRange(location: start, length: cursor + 2 - start), true)
    }

    private static func taskMarker(
        source: MarkdownSource,
        from start: Int,
        to end: Int
    ) -> (range: NSRange, isChecked: Bool)? {
        guard start + 2 < end, source[start] == 0x5B, source[start + 2] == 0x5D else { return nil }
        let state = source[start + 1]
        switch state {
        case 0x20:
            return (NSRange(location: start, length: 3), false)
        case 0x78, 0x58:
            return (NSRange(location: start, length: 3), true)
        default:
            return nil
        }
    }
}
