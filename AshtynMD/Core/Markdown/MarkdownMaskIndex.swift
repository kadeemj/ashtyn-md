import Foundation

/// The constructs that suppress other Markdown parsing inside them.
///
/// This is the single masking pass shared by the editor styler and the
/// indexer's metadata parser, so a `#tag` written inside a code fence, an
/// inline code span, a link destination, an autolink, or YAML front matter is
/// recognized as "not a tag" in exactly one place.
struct MarkdownMaskIndex: Sendable {
    struct Fence: Sendable, Equatable {
        var openMarker: NSRange
        var infoString: NSRange?
        var closeMarker: NSRange?
        /// Global line indices covered by the fence, markers included.
        var lines: Range<Int>
    }

    struct InlineCode: Sendable, Equatable {
        var full: NSRange
        var openDelimiter: NSRange
        var content: NSRange
        var closeDelimiter: NSRange
    }

    struct Link: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case inline, image, autolink, wiki }
        var kind: Kind
        var full: NSRange
        /// `!` for images, `[[`/`]]` for wiki links, `[`/`](`/`)` otherwise.
        var markers: [NSRange]
        var text: NSRange?
        var destination: NSRange?
    }

    var frontMatter: NSRange?
    var fences: [Fence] = []
    var inlineCode: [InlineCode] = []
    var comments: [NSRange] = []
    var links: [Link] = []
    var escapes: [NSRange] = []
    /// Global line indices that sit inside a fenced code block or front
    /// matter, markers included.
    var maskedLines: Set<Int> = []
    /// Sorted, non-overlapping union of everything that suppresses tags.
    private(set) var maskedRanges: [NSRange] = []
    /// Whether a fence was still open when the scanned region ended.
    var endsInsideFence = false

    /// True when any part of `range` falls inside a masked construct.
    func isMasked(_ range: NSRange) -> Bool {
        guard !maskedRanges.isEmpty else { return false }
        var low = 0
        var high = maskedRanges.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let candidate = maskedRanges[middle]
            if NSMaxRange(candidate) <= range.location {
                low = middle + 1
            } else if candidate.location >= NSMaxRange(range) {
                high = middle - 1
            } else {
                return true
            }
        }
        return false
    }

    // MARK: - Building

    /// Scans `lines` of `source`, starting with `fenceState` telling whether
    /// the first line is already inside a fenced code block.
    ///
    /// `detectFrontMatter` is only meaningful when the scan starts at line 0.
    static func build(
        source: MarkdownSource,
        lines: Range<Int>,
        fenceState: Bool = false,
        detectFrontMatter: Bool = true
    ) -> MarkdownMaskIndex {
        var index = MarkdownMaskIndex()
        var masked: [NSRange] = []
        var lineIndex = lines.lowerBound
        var openFence: (character: unichar, run: Int, startLine: Int, marker: NSRange, info: NSRange?)?

        if fenceState {
            // We were handed a mid-fence starting point; treat it as an
            // already-open fence with no visible opening marker.
            openFence = (0x60, 3, lines.lowerBound, NSRange(location: source.line(lines.lowerBound).location, length: 0), nil)
        }

        if detectFrontMatter, lines.lowerBound == 0, source.lineCount > 1,
           isFrontMatterDelimiter(source, line: 0) {
            var closing: Int?
            var candidate = 1
            while candidate < source.lineCount {
                if isFrontMatterDelimiter(source, line: candidate) {
                    closing = candidate
                    break
                }
                candidate += 1
            }
            if let closing {
                let start = source.line(0).location
                let end = NSMaxRange(source.line(closing))
                let range = NSRange(location: start, length: end - start)
                index.frontMatter = range
                masked.append(range)
                for line in 0...closing { index.maskedLines.insert(line) }
                lineIndex = max(lineIndex, closing + 1)
            }
        }

        while lineIndex < lines.upperBound {
            let line = source.line(lineIndex)
            if index.maskedLines.contains(lineIndex) {
                lineIndex += 1
                continue
            }

            if var fence = openFence {
                index.maskedLines.insert(lineIndex)
                masked.append(line)
                if let closeRun = fenceRun(source, line: line, character: fence.character),
                   closeRun.length >= fence.run,
                   isBlankAfter(source, line: line, from: NSMaxRange(closeRun.range)) {
                    index.fences.append(
                        Fence(
                            openMarker: fence.marker,
                            infoString: fence.info,
                            closeMarker: closeRun.range,
                            lines: fence.startLine..<(lineIndex + 1)
                        )
                    )
                    openFence = nil
                } else {
                    fence.startLine = fence.startLine
                    openFence = fence
                }
                lineIndex += 1
                continue
            }

            if let opening = openingFence(source, line: line) {
                openFence = (
                    character: opening.character,
                    run: opening.length,
                    startLine: lineIndex,
                    marker: opening.marker,
                    info: opening.info
                )
                index.maskedLines.insert(lineIndex)
                masked.append(line)
                lineIndex += 1
                continue
            }

            index.scanInline(source: source, line: line, masked: &masked)
            lineIndex += 1
        }

        if let fence = openFence {
            index.fences.append(
                Fence(
                    openMarker: fence.marker,
                    infoString: fence.info,
                    closeMarker: nil,
                    lines: fence.startLine..<lines.upperBound
                )
            )
            index.endsInsideFence = true
        }

        index.maskedRanges = normalize(masked)
        return index
    }

    // MARK: - Inline masking

    private mutating func scanInline(source: MarkdownSource, line: NSRange, masked: inout [NSRange]) {
        var index = line.location
        let end = NSMaxRange(line)

        while index < end {
            let character = source[index]

            // Backslash escape: consume the pair so the escaped character can
            // never act as a delimiter.
            if character == 0x5C, index + 1 < end, source[index + 1].isMarkdownASCIIPunctuation {
                let range = NSRange(location: index, length: 2)
                escapes.append(range)
                masked.append(range)
                index += 2
                continue
            }

            // HTML comment, possibly running past the end of this line.
            if character == 0x3C, matches(source, at: index, "<!--") {
                let commentEnd = findSequence(source, from: index + 4, "-->") ?? source.length
                let stop = min(commentEnd + 3, source.length)
                let range = NSRange(location: index, length: stop - index)
                comments.append(range)
                masked.append(range)
                for line in source.lineIndices(intersecting: range) where line > 0 {
                    // Whole-line masking only matters for interior lines; the
                    // range mask already covers the partial first/last lines.
                    if range.location <= source.line(line).location,
                       NSMaxRange(source.line(line)) <= NSMaxRange(range) {
                        maskedLines.insert(line)
                    }
                }
                index = stop
                continue
            }

            // Inline code span: a run of N backticks closed by a run of
            // exactly N on the same line.
            if character == 0x60 {
                var runEnd = index
                while runEnd < end, source[runEnd] == 0x60 { runEnd += 1 }
                let runLength = runEnd - index
                if let closer = findBacktickRun(source, from: runEnd, to: end, length: runLength) {
                    let full = NSRange(location: index, length: NSMaxRange(closer) - index)
                    inlineCode.append(
                        InlineCode(
                            full: full,
                            openDelimiter: NSRange(location: index, length: runLength),
                            content: NSRange(location: runEnd, length: closer.location - runEnd),
                            closeDelimiter: closer
                        )
                    )
                    masked.append(full)
                    index = NSMaxRange(closer)
                    continue
                }
                index = runEnd
                continue
            }

            // Autolink.
            if character == 0x3C, let autolink = parseAutolink(source, from: index, to: end) {
                links.append(autolink)
                if let destination = autolink.destination { masked.append(destination) }
                index = NSMaxRange(autolink.full)
                continue
            }

            // Wiki link.
            if character == 0x5B, matches(source, at: index, "[["),
               let wiki = parseWikiLink(source, from: index, to: end) {
                links.append(wiki)
                index = NSMaxRange(wiki.full)
                continue
            }

            // Inline link or image. The destination is masked; the link text
            // is deliberately left scannable so `[see #work](url)` still tags.
            if character == 0x5B || (character == 0x21 && index + 1 < end && source[index + 1] == 0x5B) {
                if let link = parseInlineLink(source, from: index, to: end) {
                    links.append(link)
                    if let destination = link.destination { masked.append(destination) }
                    index = NSMaxRange(link.full)
                    continue
                }
            }

            index += 1
        }
    }

    // MARK: - Fence helpers

    private static func isFrontMatterDelimiter(_ source: MarkdownSource, line index: Int) -> Bool {
        let line = source.line(index)
        guard line.length >= 3 else { return false }
        for offset in 0..<3 where source[line.location + offset] != 0x2D { return false }
        for offset in 3..<line.length where !source[line.location + offset].isMarkdownWhitespace {
            return false
        }
        return true
    }

    private static func openingFence(
        _ source: MarkdownSource,
        line: NSRange
    ) -> (character: unichar, length: Int, marker: NSRange, info: NSRange?)? {
        var index = line.location
        var indent = 0
        while index < NSMaxRange(line), source[index].isMarkdownWhitespace, indent < 4 {
            index += 1
            indent += 1
        }
        guard indent < 4, index < NSMaxRange(line) else { return nil }
        let character = source[index]
        guard character == 0x60 || character == 0x7E else { return nil }
        var runEnd = index
        while runEnd < NSMaxRange(line), source[runEnd] == character { runEnd += 1 }
        let length = runEnd - index
        guard length >= 3 else { return nil }

        var infoStart = runEnd
        while infoStart < NSMaxRange(line), source[infoStart].isMarkdownWhitespace { infoStart += 1 }
        var infoEnd = NSMaxRange(line)
        while infoEnd > infoStart, source[infoEnd - 1].isMarkdownWhitespace { infoEnd -= 1 }
        // A backtick fence's info string may not contain a backtick.
        if character == 0x60 {
            for offset in infoStart..<infoEnd where source[offset] == 0x60 { return nil }
        }
        let info = infoEnd > infoStart
            ? NSRange(location: infoStart, length: infoEnd - infoStart)
            : nil
        return (character, length, NSRange(location: index, length: length), info)
    }

    private static func fenceRun(
        _ source: MarkdownSource,
        line: NSRange,
        character: unichar
    ) -> (range: NSRange, length: Int)? {
        var index = line.location
        var indent = 0
        while index < NSMaxRange(line), source[index].isMarkdownWhitespace, indent < 4 {
            index += 1
            indent += 1
        }
        guard indent < 4, index < NSMaxRange(line), source[index] == character else { return nil }
        var runEnd = index
        while runEnd < NSMaxRange(line), source[runEnd] == character { runEnd += 1 }
        let length = runEnd - index
        guard length >= 3 else { return nil }
        return (NSRange(location: index, length: length), length)
    }

    private static func isBlankAfter(_ source: MarkdownSource, line: NSRange, from index: Int) -> Bool {
        var cursor = index
        while cursor < NSMaxRange(line) {
            if !source[cursor].isMarkdownWhitespace { return false }
            cursor += 1
        }
        return true
    }

    // MARK: - Inline helpers

    private func matches(_ source: MarkdownSource, at index: Int, _ text: String) -> Bool {
        let units = Array(text.utf16)
        guard index + units.count <= source.length else { return false }
        for (offset, unit) in units.enumerated() where source[index + offset] != unit {
            return false
        }
        return true
    }

    private func findSequence(_ source: MarkdownSource, from index: Int, _ text: String) -> Int? {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return nil }
        var cursor = index
        while cursor + units.count <= source.length {
            var matched = true
            for (offset, unit) in units.enumerated() where source[cursor + offset] != unit {
                matched = false
                break
            }
            if matched { return cursor }
            cursor += 1
        }
        return nil
    }

    private func findBacktickRun(
        _ source: MarkdownSource,
        from index: Int,
        to end: Int,
        length: Int
    ) -> NSRange? {
        var cursor = index
        while cursor < end {
            guard source[cursor] == 0x60 else {
                cursor += 1
                continue
            }
            var runEnd = cursor
            while runEnd < end, source[runEnd] == 0x60 { runEnd += 1 }
            if runEnd - cursor == length {
                return NSRange(location: cursor, length: length)
            }
            cursor = runEnd
        }
        return nil
    }

    private func parseAutolink(_ source: MarkdownSource, from index: Int, to end: Int) -> Link? {
        var cursor = index + 1
        var sawScheme = false
        while cursor < end {
            let character = source[cursor]
            if character == 0x3E {
                guard sawScheme, cursor > index + 1 else { return nil }
                let inner = NSRange(location: index + 1, length: cursor - index - 1)
                return Link(
                    kind: .autolink,
                    full: NSRange(location: index, length: cursor - index + 1),
                    markers: [
                        NSRange(location: index, length: 1),
                        NSRange(location: cursor, length: 1),
                    ],
                    text: nil,
                    destination: inner
                )
            }
            if character.isMarkdownWhitespace || character == 0x3C { return nil }
            if character == 0x3A { sawScheme = true }
            cursor += 1
        }
        return nil
    }

    private func parseWikiLink(_ source: MarkdownSource, from index: Int, to end: Int) -> Link? {
        var cursor = index + 2
        while cursor + 1 < end {
            if source[cursor] == 0x5D, source[cursor + 1] == 0x5D {
                let inner = NSRange(location: index + 2, length: cursor - index - 2)
                guard inner.length > 0 else { return nil }
                return Link(
                    kind: .wiki,
                    full: NSRange(location: index, length: cursor + 2 - index),
                    markers: [
                        NSRange(location: index, length: 2),
                        NSRange(location: cursor, length: 2),
                    ],
                    text: inner,
                    destination: nil
                )
            }
            cursor += 1
        }
        return nil
    }

    private func parseInlineLink(_ source: MarkdownSource, from index: Int, to end: Int) -> Link? {
        let isImage = source[index] == 0x21
        let bracket = isImage ? index + 1 : index
        guard bracket < end, source[bracket] == 0x5B else { return nil }

        var depth = 0
        var cursor = bracket
        var textEnd: Int?
        while cursor < end {
            let character = source[cursor]
            if character == 0x5C { cursor += 2; continue }
            if character == 0x5B { depth += 1 }
            if character == 0x5D {
                depth -= 1
                if depth == 0 { textEnd = cursor; break }
            }
            cursor += 1
        }
        guard let textEnd, textEnd + 1 < end, source[textEnd + 1] == 0x28 else { return nil }

        var destinationDepth = 1
        var destinationCursor = textEnd + 2
        while destinationCursor < end {
            let character = source[destinationCursor]
            if character == 0x5C { destinationCursor += 2; continue }
            if character == 0x28 { destinationDepth += 1 }
            if character == 0x29 {
                destinationDepth -= 1
                if destinationDepth == 0 { break }
            }
            destinationCursor += 1
        }
        guard destinationCursor < end, source[destinationCursor] == 0x29 else { return nil }

        var markers = [
            NSRange(location: bracket, length: 1),
            NSRange(location: textEnd, length: 2),
            NSRange(location: destinationCursor, length: 1),
        ]
        if isImage { markers.insert(NSRange(location: index, length: 1), at: 0) }

        return Link(
            kind: isImage ? .image : .inline,
            full: NSRange(location: index, length: destinationCursor + 1 - index),
            markers: markers,
            text: NSRange(location: bracket + 1, length: textEnd - bracket - 1),
            destination: NSRange(
                location: textEnd + 2,
                length: destinationCursor - textEnd - 2
            )
        )
    }

    private static func normalize(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if var last = merged.last, NSMaxRange(last) >= range.location {
                last.length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
