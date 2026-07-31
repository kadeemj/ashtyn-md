import Foundation
import Testing

@testable import AshtynMD

@Suite("Fuzzy match")
struct FuzzyMatchTests {
    private func value(_ pattern: String, _ candidate: String) -> Double? {
        FuzzyMatch.score(pattern: pattern, in: candidate)?.value
    }

    @Test("a subsequence matches")
    func subsequence() {
        #expect(value("wr", "Weekly Review") != nil)
        #expect(value("weekly", "Weekly Review") != nil)
        #expect(value("wklyrv", "Weekly Review") != nil)
    }

    @Test("a non-subsequence does not match")
    func nonSubsequence() {
        #expect(value("zz", "Weekly Review") == nil)
        #expect(value("review weekly", "Weekly Review") == nil)
    }

    @Test("a pattern longer than the candidate does not match")
    func tooLong() {
        #expect(value("weekly review notes", "Weekly") == nil)
    }

    @Test("an empty pattern matches everything")
    func emptyPattern() {
        #expect(value("", "Anything") == 0)
    }

    @Test("matching is case insensitive")
    func caseInsensitive() {
        #expect(value("WEEKLY", "weekly review") != nil)
        #expect(value("weekly", "WEEKLY REVIEW") != nil)
    }

    @Test("word starts outrank mid-word hits")
    func wordStartBonus() {
        let wordStarts = value("wr", "Weekly Review")!
        let midWord = value("wr", "Wireframes")!
        #expect(wordStarts > midWord)
    }

    @Test("consecutive runs outrank scattered hits")
    func consecutiveBonus() {
        let consecutive = value("week", "Weekly Notes")!
        let scattered = value("week", "Wednesday Evening Kickoff")!
        #expect(consecutive > scattered)
    }

    @Test("a prefix match outranks a later match")
    func prefixBonus() {
        let prefix = value("rev", "Review Notes")!
        let later = value("rev", "Monthly Review")!
        #expect(prefix > later)
    }

    @Test("shorter candidates outrank longer ones for the same match")
    func lengthPenalty() {
        let short = value("todo", "Todo")!
        let long = value("todo", "Todo list for the entire quarter and beyond")!
        #expect(short > long)
    }

    @Test("camelCase boundaries count as word starts")
    func camelCase() {
        let camel = value("wr", "weeklyReview")!
        let plain = value("wr", "weeklyreview")!
        #expect(camel > plain)
    }

    @Test("spaces in the pattern are ignored")
    func patternSpaces() {
        #expect(value("wee rev", "Weekly Review") != nil)
    }

    @Test("matched ranges are UTF-16 correct and merged into runs")
    func matchedRanges() {
        let candidate = "Weekly Review"
        let score = FuzzyMatch.score(pattern: "week", in: candidate)!
        #expect(score.ranges.count == 1)
        #expect((candidate as NSString).substring(with: score.ranges[0]) == "Week")

        let split = FuzzyMatch.score(pattern: "wr", in: candidate)!
        #expect(split.ranges.count == 2)
        #expect((candidate as NSString).substring(with: split.ranges[0]) == "W")
        #expect((candidate as NSString).substring(with: split.ranges[1]) == "R")
    }

    @Test("ranges stay correct past an emoji")
    func emojiRanges() {
        let candidate = "🎉 Party Plan"
        let score = FuzzyMatch.score(pattern: "plan", in: candidate)!
        #expect((candidate as NSString).substring(with: score.ranges[0]) == "Plan")
    }

    @Test("ranking a realistic set puts the obvious answer first")
    func ranking() {
        let candidates = [
            "Wireframes",
            "Weekly Review",
            "Work Retrospective",
            "Notes on writing",
        ]
        let ranked = candidates
            .compactMap { candidate -> (String, Double)? in
                FuzzyMatch.score(pattern: "wr", in: candidate).map { (candidate, $0.value) }
            }
            .sorted { $0.1 > $1.1 }
        #expect(ranked.first?.0 == "Weekly Review" || ranked.first?.0 == "Work Retrospective")
        #expect(ranked.last?.0 == "Wireframes")
    }
}
