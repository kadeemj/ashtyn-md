import Foundation

/// Subsequence scoring for the quick-open palette.
///
/// Deliberately small and dependency-free: the palette prefilters candidates
/// through FTS, so this only ever ranks a few hundred short titles and does not
/// need a full Smith-Waterman.
enum FuzzyMatch {
    struct Score: Sendable, Equatable {
        let value: Double
        /// Matched character positions in the candidate, for bolding.
        let ranges: [NSRange]
    }

    /// Bonus for matching at the start of a word — `wr` should rank
    /// "Weekly Review" above "Wireframes".
    private static let wordStartBonus = 8.0
    /// Bonus for each character that continues an unbroken run.
    private static let consecutiveBonus = 6.0
    /// Bonus for matching the very first character.
    private static let prefixBonus = 10.0
    /// Penalty per skipped character, so tight matches win.
    private static let gapPenalty = 0.6
    /// Penalty applied once, scaled by how much longer the candidate is.
    private static let lengthPenalty = 0.05

    /// Small penalty on how far into the candidate the first match sits.
    private static let leadingOffsetPenalty = 0.1
    private static let negativeInfinity = -Double.greatestFiniteMagnitude

    /// Returns nil when `pattern` is not a subsequence of `candidate`.
    ///
    /// Matching is case-insensitive; an empty pattern matches everything with a
    /// score of zero so an empty palette query can still list recents.
    ///
    /// This is a dynamic program rather than a greedy left-to-right scan
    /// because greedy picks the *first* occurrence of each character, not the
    /// best one: searching "wr" would match the `r` in "Work" instead of the
    /// `R` in "Retrospective" and rank the result below "Wireframes". Finding
    /// the optimal alignment is what makes word-start and consecutive-run
    /// bonuses actually mean anything.
    static func score(pattern: String, in candidate: String) -> Score? {
        // Whitespace in the pattern is ignored, so "wee rev" matches too.
        // Array(), not a bare filter: RangeReplaceableCollection.filter would
        // hand back a UnicodeScalarView indexed by String.Index.
        let needle = Array(pattern.lowercased().unicodeScalars).filter {
            !CharacterSet.whitespaces.contains($0)
        }
        let candidateScalars = Array(candidate.unicodeScalars)
        let haystack = Array(candidate.lowercased().unicodeScalars)

        guard !needle.isEmpty else { return Score(value: 0, ranges: []) }
        guard needle.count <= haystack.count else { return nil }

        let patternCount = needle.count
        let candidateCount = haystack.count

        var positionBonus = [Double](repeating: 0, count: candidateCount)
        for index in 0..<candidateCount {
            if index == 0 {
                positionBonus[index] = prefixBonus
            } else if isWordStart(candidateScalars, at: index) {
                positionBonus[index] = wordStartBonus
            }
        }

        // `match[i][j]`  best score with pattern[i] landing on candidate[j].
        // `best[i][j]`   best score for pattern[0...i] within candidate[0...j].
        // `bestIndex`    which j achieved `best`, so the alignment can be
        //                reconstructed for highlight ranges.
        var match = [[Double]](
            repeating: [Double](repeating: negativeInfinity, count: candidateCount),
            count: patternCount
        )
        var best = match
        var bestIndex = [[Int]](
            repeating: [Int](repeating: -1, count: candidateCount),
            count: patternCount
        )
        var cameFromConsecutive = [[Bool]](
            repeating: [Bool](repeating: false, count: candidateCount),
            count: patternCount
        )

        for i in 0..<patternCount {
            for j in 0..<candidateCount {
                var score = negativeInfinity
                if haystack[j] == needle[i] {
                    if i == 0 {
                        score = 1 + positionBonus[j] - Double(j) * leadingOffsetPenalty
                    } else if j > 0 {
                        let afterGap = best[i - 1][j - 1]
                        let afterRun = match[i - 1][j - 1]
                        var candidateScore = negativeInfinity
                        if afterGap > negativeInfinity {
                            candidateScore = afterGap + 1 + positionBonus[j]
                        }
                        if afterRun > negativeInfinity {
                            let runScore = afterRun + 1 + positionBonus[j] + consecutiveBonus
                            if runScore >= candidateScore {
                                candidateScore = runScore
                                cameFromConsecutive[i][j] = true
                            }
                        }
                        score = candidateScore
                    }
                }
                match[i][j] = score

                let skip = j > 0 && best[i][j - 1] > negativeInfinity
                    ? best[i][j - 1] - gapPenalty
                    : negativeInfinity
                if score >= skip {
                    best[i][j] = score
                    bestIndex[i][j] = j
                } else {
                    best[i][j] = skip
                    bestIndex[i][j] = bestIndex[i][j - 1]
                }
            }
        }

        // Best final landing spot, taken from `match` so trailing characters
        // are only charged once, by the length penalty below.
        var endIndex = -1
        var total = negativeInfinity
        for j in 0..<candidateCount where match[patternCount - 1][j] > total {
            total = match[patternCount - 1][j]
            endIndex = j
        }
        guard endIndex >= 0, total > negativeInfinity else { return nil }

        var positions = [Int](repeating: 0, count: patternCount)
        var cursor = endIndex
        for i in stride(from: patternCount - 1, through: 0, by: -1) {
            positions[i] = cursor
            guard i > 0 else { break }
            cursor = cameFromConsecutive[i][cursor] ? cursor - 1 : bestIndex[i - 1][cursor - 1]
            guard cursor >= 0 else { return nil }
        }

        total -= Double(candidateCount - patternCount) * lengthPenalty
        return Score(value: total, ranges: mergeRanges(positions, in: candidate))
    }

    private static func isWordStart(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = scalars[index - 1]
        if CharacterSet.whitespaces.contains(previous) { return true }
        if CharacterSet.punctuationCharacters.contains(previous) { return true }
        // camelCase boundary.
        let current = scalars[index]
        if CharacterSet.lowercaseLetters.contains(previous),
           CharacterSet.uppercaseLetters.contains(current) {
            return true
        }
        return false
    }

    /// Converts matched scalar positions into UTF-16 ranges, merging runs so
    /// the palette draws one attribute per streak rather than per character.
    private static func mergeRanges(_ positions: [Int], in candidate: String) -> [NSRange] {
        guard !positions.isEmpty else { return [] }

        // Scalar index -> UTF-16 offset.
        var utf16Offsets: [Int] = []
        utf16Offsets.reserveCapacity(candidate.unicodeScalars.count)
        var offset = 0
        for scalar in candidate.unicodeScalars {
            utf16Offsets.append(offset)
            offset += UTF16.width(scalar)
        }
        utf16Offsets.append(offset)

        var ranges: [NSRange] = []
        var runStart = positions[0]
        var runEnd = positions[0]
        for position in positions.dropFirst() {
            if position == runEnd + 1 {
                runEnd = position
            } else {
                ranges.append(range(runStart, through: runEnd, offsets: utf16Offsets))
                runStart = position
                runEnd = position
            }
        }
        ranges.append(range(runStart, through: runEnd, offsets: utf16Offsets))
        return ranges
    }

    private static func range(_ start: Int, through end: Int, offsets: [Int]) -> NSRange {
        let location = offsets[start]
        let limit = offsets[min(end + 1, offsets.count - 1)]
        return NSRange(location: location, length: max(0, limit - location))
    }
}
