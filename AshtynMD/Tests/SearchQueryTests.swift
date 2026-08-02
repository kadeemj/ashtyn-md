import Testing

@testable import AshtynMD

@Suite("Search query FTS expression")
struct SearchQueryTests {
    @Test("returns nil for empty or whitespace-only input")
    func emptyInputReturnsNil() {
        #expect(SearchQuery.ftsMatchExpression(for: "") == nil)
        #expect(SearchQuery.ftsMatchExpression(for: "   ") == nil)
    }

    @Test("quotes a single term and appends a prefix wildcard")
    func singleTermIsQuotedWithWildcard() {
        #expect(SearchQuery.ftsMatchExpression(for: "alpha") == "\"alpha\"*")
    }

    @Test("quotes each whitespace-separated term independently")
    func multipleTermsAreQuotedSeparately() {
        #expect(SearchQuery.ftsMatchExpression(for: "alpha beta") == "\"alpha\" \"beta\"*")
    }

    @Test("escapes an embedded double quote so it cannot break out of the FTS term")
    func embeddedQuoteIsEscaped() {
        #expect(SearchQuery.ftsMatchExpression(for: #"a"b"#) == #""a""b"*"#)
    }

    @Test("a bare FTS boolean operator is quoted rather than interpreted")
    func ftsOperatorIsQuotedNotInterpreted() {
        #expect(
            SearchQuery.ftsMatchExpression(for: "alpha NOT beta")
                == "\"alpha\" \"NOT\" \"beta\"*"
        )
    }
}
