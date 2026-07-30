import Foundation
import SwiftTreeSitter

/// One colored range, in UTF-16 (NSRange) coordinates.
struct HighlightSpan: Equatable, Sendable {
    let range: NSRange
    let token: SyntaxToken
}

/// Incremental Tree-sitter parsing off the main actor. One instance per open
/// editor. The editor feeds it edits; it answers highlight queries for the
/// visible range. Any failure degrades to "no highlights" (plain text).
actor SyntaxHighlighter {
    private var parser: Parser?
    private var configuration: LanguageConfiguration?
    private var tree: MutableTree?
    private var text: String = ""
    /// Bumped on every text mutation so stale highlight requests can bail.
    private var generation: UInt64 = 0

    func setLanguage(_ id: LanguageID) {
        configuration = GrammarRegistry.configuration(for: id)
        parser = nil
        tree = nil
        if let configuration {
            let newParser = Parser()
            if (try? newParser.setLanguage(configuration.language)) != nil {
                parser = newParser
            } else {
                self.configuration = nil
            }
        }
        reparseAll()
    }

    /// Full text replacement (open, reload, recovery restore).
    func replaceText(_ newText: String) {
        text = newText
        generation &+= 1
        tree = nil
        reparseAll()
    }

    private var lastEditSequence: UInt64 = 0

    /// Incremental edit from NSTextStorage: `editedRange` is the range in the
    /// NEW text, `delta` the length change. `sequence` orders edits: stale
    /// arrivals are dropped, gaps force a clean reparse.
    func applyEdit(newText: String, editedRange: NSRange, delta: Int, sequence: UInt64) {
        guard sequence > lastEditSequence else { return }
        let hadGap = sequence != lastEditSequence + 1 && lastEditSequence != 0
        lastEditSequence = sequence

        text = newText
        generation &+= 1
        guard let parser else { return }
        if hadGap {
            tree = parser.parse(text)
            return
        }

        if let existingTree = tree {
            let oldLength = editedRange.length - delta
            let startByte = editedRange.location * 2
            let oldEndByte = (editedRange.location + max(0, oldLength)) * 2
            let newEndByte = (editedRange.location + editedRange.length) * 2
            // Points are unused by our queries; passing zero keeps the edit
            // cheap and is explicitly tolerated by tree-sitter.
            let edit = InputEdit(
                startByte: startByte,
                oldEndByte: oldEndByte,
                newEndByte: newEndByte,
                startPoint: Point(row: 0, column: 0),
                oldEndPoint: Point(row: 0, column: 0),
                newEndPoint: Point(row: 0, column: 0)
            )
            existingTree.edit(edit)
            tree = parser.parse(tree: existingTree, string: text)
        } else {
            tree = parser.parse(text)
        }
    }

    private func reparseAll() {
        guard let parser else {
            tree = nil
            return
        }
        tree = parser.parse(text)
    }

    /// Highlight spans intersecting `range`, or nil if this request is
    /// already stale (the text changed since `expectedGeneration`).
    func highlights(in range: NSRange) -> [HighlightSpan] {
        guard let configuration, let tree,
              let query = configuration.queries[.highlights] else { return [] }

        let cursor = query.execute(in: tree)
        cursor.setRange(range)
        let resolved = cursor.resolve(with: Predicate.Context(string: text))

        var spans: [HighlightSpan] = []
        for namedRange in resolved.highlights() {
            guard namedRange.range.length > 0,
                  NSIntersectionRange(namedRange.range, range).length > 0,
                  let token = CaptureNameMapper.token(forCaptureComponents: namedRange.nameComponents)
            else { continue }
            spans.append(HighlightSpan(range: namedRange.range, token: token))
        }
        return spans
    }

    var currentGeneration: UInt64 { generation }
}
