import Foundation
import Markdown

/// Rendering policy. Raw HTML is escaped and remote images are blocked
/// unless the library explicitly opts in.
struct MarkdownRenderPolicy: Sendable, Equatable {
    var allowRawHTML = false
    var allowRemoteImages = false

    static let `default` = MarkdownRenderPolicy()
}

/// Converts GitHub-flavored Markdown to safe HTML. Every text node is
/// entity-escaped; raw HTML becomes visible text unless explicitly allowed.
/// Local images are routed through the restricted ashtyn-file: scheme by the
/// preview's base URL; remote images render as a blocked placeholder.
struct MarkdownHTMLRenderer {
    var policy: MarkdownRenderPolicy = .default

    /// Body HTML for the given Markdown source.
    func renderBody(_ markdown: String) -> String {
        let document = Document(parsing: markdown)
        var visitor = Visitor(policy: policy)
        return visitor.visit(document)
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private struct Visitor: MarkupVisitor {
        typealias Result = String

        let policy: MarkdownRenderPolicy
        /// Running index assigned to task-list checkboxes, matching the order
        /// MarkdownTasks finds them in the source.
        var taskIndex = 0

        mutating func defaultVisit(_ markup: Markup) -> String {
            visitChildren(markup)
        }

        mutating func visitChildren(_ markup: Markup) -> String {
            markup.children.map { visit($0) }.joined()
        }

        mutating func visitDocument(_ document: Document) -> String {
            visitChildren(document)
        }

        mutating func visitHeading(_ heading: Heading) -> String {
            let level = min(max(heading.level, 1), 6)
            return "<h\(level)>\(visitChildren(heading))</h\(level)>\n"
        }

        mutating func visitParagraph(_ paragraph: Paragraph) -> String {
            "<p>\(visitChildren(paragraph))</p>\n"
        }

        mutating func visitText(_ text: Markdown.Text) -> String {
            // Bare-URL autolinks: cmark only autolinks <angle-bracket> forms,
            // GitHub-flavored rendering links bare URLs too. Skip inside an
            // existing link.
            if text.parent is Markdown.Link {
                return MarkdownHTMLRenderer.escape(text.string)
            }
            return Self.linkifyBareURLs(in: text.string)
        }

        private static let bareURLRegex = try! NSRegularExpression(
            pattern: #"https?://[^\s<>"')\]]+"#
        )

        static func linkifyBareURLs(in text: String) -> String {
            let ns = text as NSString
            let matches = bareURLRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return MarkdownHTMLRenderer.escape(text) }
            var html = ""
            var cursor = 0
            for match in matches {
                html += MarkdownHTMLRenderer.escape(
                    ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                )
                let url = MarkdownHTMLRenderer.escape(ns.substring(with: match.range))
                html += "<a href=\"\(url)\">\(url)</a>"
                cursor = NSMaxRange(match.range)
            }
            html += MarkdownHTMLRenderer.escape(ns.substring(from: cursor))
            return html
        }

        mutating func visitEmphasis(_ emphasis: Markdown.Emphasis) -> String {
            "<em>\(visitChildren(emphasis))</em>"
        }

        mutating func visitStrong(_ strong: Strong) -> String {
            "<strong>\(visitChildren(strong))</strong>"
        }

        mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
            "<del>\(visitChildren(strikethrough))</del>"
        }

        mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
            "<code>\(MarkdownHTMLRenderer.escape(inlineCode.code))</code>"
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
            let languageClass = codeBlock.language
                .map { " class=\"language-\(MarkdownHTMLRenderer.escape($0))\"" } ?? ""
            return "<pre><code\(languageClass)>\(MarkdownHTMLRenderer.escape(codeBlock.code))</code></pre>\n"
        }

        mutating func visitLink(_ link: Markdown.Link) -> String {
            let destination = MarkdownHTMLRenderer.escape(link.destination ?? "")
            return "<a href=\"\(destination)\">\(visitChildren(link))</a>"
        }

        mutating func visitImage(_ image: Markdown.Image) -> String {
            let source = image.source ?? ""
            let alt = MarkdownHTMLRenderer.escape(image.plainText)
            let lowered = source.lowercased()

            if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
                guard policy.allowRemoteImages else {
                    return "<span class=\"blocked-image\" title=\"Remote image blocked\">🖼 \(alt.isEmpty ? "Remote image blocked" : alt)</span>"
                }
                return "<img src=\"\(MarkdownHTMLRenderer.escape(source))\" alt=\"\(alt)\">"
            }
            // Reject non-relative schemes (file:, data:, javascript:, …).
            if source.contains(":") || source.hasPrefix("//") {
                return "<span class=\"blocked-image\">🖼 \(alt.isEmpty ? "Image blocked" : alt)</span>"
            }
            // Relative path: resolved against the preview's restricted base URL.
            return "<img src=\"\(MarkdownHTMLRenderer.escape(source))\" alt=\"\(alt)\">"
        }

        mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
            let isTaskList = unorderedList.listItems.contains { $0.checkbox != nil }
            let cssClass = isTaskList ? " class=\"task-list\"" : ""
            return "<ul\(cssClass)>\n\(visitChildren(unorderedList))</ul>\n"
        }

        mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
            let start = orderedList.startIndex
            let startAttribute = start != 1 ? " start=\"\(start)\"" : ""
            return "<ol\(startAttribute)>\n\(visitChildren(orderedList))</ol>\n"
        }

        mutating func visitListItem(_ listItem: ListItem) -> String {
            if let checkbox = listItem.checkbox {
                let checked = checkbox == .checked ? " checked" : ""
                let index = taskIndex
                taskIndex += 1
                return "<li class=\"task\"><input type=\"checkbox\" data-task-index=\"\(index)\"\(checked)>\(listItemBody(listItem))</li>\n"
            }
            return "<li>\(listItemBody(listItem))</li>\n"
        }

        /// GitHub-style tight rendering: a leading paragraph in a list item
        /// is inlined rather than wrapped in <p>.
        private mutating func listItemBody(_ listItem: ListItem) -> String {
            var html = ""
            for (offset, child) in listItem.children.enumerated() {
                if offset == 0, let paragraph = child as? Paragraph {
                    html += visitChildren(paragraph)
                } else {
                    html += visit(child)
                }
            }
            return html
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
            "<blockquote>\n\(visitChildren(blockQuote))</blockquote>\n"
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
            "<hr>\n"
        }

        mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
            "\n"
        }

        mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
            "<br>\n"
        }

        mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
            policy.allowRawHTML
                ? inlineHTML.rawHTML
                : MarkdownHTMLRenderer.escape(inlineHTML.rawHTML)
        }

        mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
            policy.allowRawHTML
                ? html.rawHTML
                : "<p>\(MarkdownHTMLRenderer.escape(html.rawHTML))</p>\n"
        }

        // MARK: Tables

        mutating func visitTable(_ table: Markdown.Table) -> String {
            var html = "<table>\n"
            html += visit(table.head)
            html += visit(table.body)
            html += "</table>\n"
            return html
        }

        mutating func visitTableHead(_ tableHead: Markdown.Table.Head) -> String {
            var html = "<thead><tr>"
            let alignments = (tableHead.parent as? Markdown.Table)?.columnAlignments ?? []
            for (column, cell) in tableHead.cells.enumerated() {
                html += "<th\(alignmentAttribute(alignments, column))>\(visitChildren(cell))</th>"
            }
            html += "</tr></thead>\n"
            return html
        }

        mutating func visitTableBody(_ tableBody: Markdown.Table.Body) -> String {
            var html = "<tbody>\n"
            let alignments = (tableBody.parent as? Markdown.Table)?.columnAlignments ?? []
            for row in tableBody.rows {
                html += "<tr>"
                for (column, cell) in row.cells.enumerated() {
                    html += "<td\(alignmentAttribute(alignments, column))>\(visitChildren(cell))</td>"
                }
                html += "</tr>\n"
            }
            html += "</tbody>\n"
            return html
        }

        private func alignmentAttribute(
            _ alignments: [Markdown.Table.ColumnAlignment?], _ column: Int
        ) -> String {
            guard column < alignments.count, let alignment = alignments[column] else { return "" }
            switch alignment {
            case .left: return " style=\"text-align:left\""
            case .center: return " style=\"text-align:center\""
            case .right: return " style=\"text-align:right\""
            }
        }
    }
}
