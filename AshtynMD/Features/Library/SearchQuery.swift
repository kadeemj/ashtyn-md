import Foundation

/// Builds the FTS5 MATCH expression for a raw user search string: quotes
/// each whitespace-separated term (so FTS5 operators embedded in a query
/// can't be interpreted as syntax) and appends `*` to the final term for
/// search-as-you-type prefix matching.
enum SearchQuery {
    static func ftsMatchExpression(for rawQuery: String) -> String? {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let terms = trimmed.split(separator: " ").map { term in
            "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        var expression = terms.joined(separator: " ")
        expression += "*"
        return expression
    }
}
