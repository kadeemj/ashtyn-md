import Foundation

/// A UTF-16 view of a document with its line table precomputed.
///
/// Every Markdown parser in this module works in UTF-16 offsets so the ranges
/// drop straight into `NSTextStorage`, `NSLayoutManager`, and
/// `DocumentSession.performSourceEdit` without conversion. Characters are held
/// in a flat array because `NSString.character(at:)` is an objc_msgSend per
/// character, which shows up badly on megabyte documents.
struct MarkdownSource: Sendable {
    let characters: [unichar]
    /// Content ranges, one per line, excluding the line terminator.
    let lineRanges: [NSRange]

    var length: Int { characters.count }
    var lineCount: Int { lineRanges.count }

    init(_ text: NSString) {
        var buffer = [unichar](repeating: 0, count: text.length)
        if text.length > 0 {
            buffer.withUnsafeMutableBufferPointer { pointer in
                text.getCharacters(
                    pointer.baseAddress!,
                    range: NSRange(location: 0, length: text.length)
                )
            }
        }
        characters = buffer

        var ranges: [NSRange] = []
        var start = 0
        var index = 0
        while index < buffer.count {
            let character = buffer[index]
            if character == 0x0A {
                ranges.append(NSRange(location: start, length: index - start))
                index += 1
                start = index
            } else if character == 0x0D {
                ranges.append(NSRange(location: start, length: index - start))
                // The editor normalizes to LF, but a stray CRLF from an
                // external write should not shift every subsequent offset.
                index += (index + 1 < buffer.count && buffer[index + 1] == 0x0A) ? 2 : 1
                start = index
            } else {
                index += 1
            }
        }
        ranges.append(NSRange(location: start, length: buffer.count - start))
        lineRanges = ranges
    }

    subscript(index: Int) -> unichar {
        characters[index]
    }

    func character(at index: Int) -> unichar? {
        guard index >= 0, index < characters.count else { return nil }
        return characters[index]
    }

    /// Index of the line containing `location`, clamped into range.
    func lineIndex(containing location: Int) -> Int {
        guard !lineRanges.isEmpty else { return 0 }
        var low = 0
        var high = lineRanges.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineRanges[middle].location <= location {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// The inclusive span of line indices touched by `range`.
    func lineIndices(intersecting range: NSRange) -> Range<Int> {
        guard !lineRanges.isEmpty else { return 0..<0 }
        let first = lineIndex(containing: range.location)
        let last = lineIndex(containing: max(range.location, NSMaxRange(range) - 1))
        return first..<(last + 1)
    }

    func string(in range: NSRange) -> String {
        guard range.location >= 0, NSMaxRange(range) <= characters.count, range.length > 0 else {
            return ""
        }
        return String(utf16CodeUnits: Array(characters[range.location..<NSMaxRange(range)]),
                      count: range.length)
    }

    func line(_ index: Int) -> NSRange {
        lineRanges[index]
    }
}

// MARK: - Character classification

extension unichar {
    var isMarkdownWhitespace: Bool {
        self == 0x20 || self == 0x09
    }

    var isMarkdownLineBreak: Bool {
        self == 0x0A || self == 0x0D
    }

    var isMarkdownDigit: Bool {
        self >= 0x30 && self <= 0x39
    }

    /// Letters, digits, and underscore across the whole Unicode range, so tags
    /// work in any script rather than only ASCII.
    var isMarkdownWordCharacter: Bool {
        if self == 0x5F { return true }
        guard let scalar = Unicode.Scalar(UInt32(self)) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    var isMarkdownASCIIPunctuation: Bool {
        switch self {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return true
        default: return false
        }
    }
}
