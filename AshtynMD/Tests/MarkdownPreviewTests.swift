import Foundation
import Testing
@testable import AshtynMD

@Suite("Markdown HTML renderer")
struct MarkdownRendererTests {
    private func render(_ markdown: String, policy: MarkdownRenderPolicy = .default) -> String {
        MarkdownHTMLRenderer(policy: policy).renderBody(markdown)
    }

    @Test func headings() {
        let html = render("# One\n\n### Three")
        #expect(html.contains("<h1>One</h1>"))
        #expect(html.contains("<h3>Three</h3>"))
    }

    @Test func emphasisAndStrong() {
        let html = render("*em* and **strong**")
        #expect(html.contains("<em>em</em>"))
        #expect(html.contains("<strong>strong</strong>"))
    }

    @Test func strikethrough() {
        #expect(render("~~gone~~").contains("<del>gone</del>"))
    }

    @Test func linksAndAutolinks() {
        let html = render("[site](https://example.com) and https://auto.example.com")
        #expect(html.contains("<a href=\"https://example.com\">site</a>"))
        #expect(html.contains("<a href=\"https://auto.example.com\">https://auto.example.com</a>"))
    }

    @Test func listsOrderedAndUnordered() {
        let html = render("- a\n- b\n\n1. x\n2. y")
        #expect(html.contains("<ul>"))
        #expect(html.contains("<li>a</li>"))
        #expect(html.contains("<ol>"))
        #expect(html.contains("<li>y</li>"))
    }

    @Test func orderedListStartIsPreserved() {
        #expect(render("5. five\n6. six").contains("<ol start=\"5\">"))
    }

    @Test func blockquote() {
        #expect(render("> quoted").contains("<blockquote>"))
    }

    @Test func inlineAndFencedCode() {
        let html = render("`inline` code\n\n```swift\nlet x = 1 < 2\n```")
        #expect(html.contains("<code>inline</code>"))
        #expect(html.contains("<pre><code class=\"language-swift\">"))
        // Code content must be escaped.
        #expect(html.contains("let x = 1 &lt; 2"))
    }

    @Test func tableWithAlignment() {
        let markdown = """
        | Left | Center | Right |
        |:-----|:------:|------:|
        | a    | b      | c     |
        """
        let html = render(markdown)
        #expect(html.contains("<table>"))
        #expect(html.contains("<th style=\"text-align:left\">Left</th>"))
        #expect(html.contains("<th style=\"text-align:center\">Center</th>"))
        #expect(html.contains("<td style=\"text-align:right\">c</td>"))
    }

    @Test func taskListRendersInteractiveCheckboxes() {
        let html = render("- [ ] open\n- [x] done")
        #expect(html.contains("<input type=\"checkbox\" data-task-index=\"0\">"))
        #expect(html.contains("<input type=\"checkbox\" data-task-index=\"1\" checked>"))
        #expect(html.contains("class=\"task-list\""))
    }

    @Test func rawHTMLIsEscapedByDefault() {
        let html = render("hello <script>alert(1)</script> world\n\n<div onclick=\"x()\">block</div>")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(!html.contains("<div onclick"))
    }

    @Test func rawHTMLPassesThroughWhenAllowed() {
        let html = render(
            "<b>bold</b>",
            policy: MarkdownRenderPolicy(allowRawHTML: true, allowRemoteImages: false)
        )
        #expect(html.contains("<b>bold</b>"))
    }

    @Test func textIsAlwaysEntityEscaped() {
        // Note: the parser applies smart punctuation to quotes, so this
        // pins the escaping of the structural characters.
        let html = render("a < b & c > d")
        #expect(html.contains("a &lt; b &amp; c &gt; d"))
    }

    @Test func relativeImagePassesThrough() {
        let html = render("![cat](Assets/cat.png)")
        #expect(html.contains("<img src=\"Assets/cat.png\" alt=\"cat\">"))
    }

    @Test func remoteImageIsBlockedByDefault() {
        let html = render("![tracker](https://evil.example.com/pixel.png)")
        #expect(!html.contains("<img"))
        #expect(html.contains("blocked-image"))
    }

    @Test func remoteImageAllowedWhenOptedIn() {
        let html = render(
            "![ok](https://example.com/a.png)",
            policy: MarkdownRenderPolicy(allowRawHTML: false, allowRemoteImages: true)
        )
        #expect(html.contains("<img src=\"https://example.com/a.png\""))
    }

    @Test func dangerousImageSchemesAreBlocked() {
        for source in ["file:///etc/passwd", "javascript:alert(1)", "data:image/png;base64,AAAA", "//evil.example.com/x.png"] {
            let html = render("![x](\(source))")
            #expect(!html.contains("<img"), Comment(rawValue: source))
        }
    }

    @Test func thematicBreakAndLineBreak() {
        #expect(render("a\n\n---\n\nb").contains("<hr>"))
        #expect(render("line one  \nline two").contains("<br>"))
    }
}

@Suite("Markdown task toggling")
struct MarkdownTaskTests {
    @Test func findsMarkersInOrder() {
        let source = """
        # Title
        - [ ] first
        - [x] second
          - [ ] nested
        1. [X] ordered task
        - not a task
        """
        let markers = MarkdownTasks.markers(in: source)
        #expect(markers.count == 4)
        #expect(markers.map(\.isChecked) == [false, true, false, true])
    }

    @Test func toggleProducesExactSourceEdit() {
        let source = "- [ ] alpha\n- [x] beta\n"
        let first = MarkdownTasks.toggleEdit(forTaskAt: 0, in: source)
        #expect(first != nil)
        if let first {
            let ns = source as NSString
            #expect(ns.substring(with: first.range) == " ")
            #expect(first.replacement == "x")
            let toggled = ns.replacingCharacters(in: first.range, with: first.replacement)
            #expect(toggled == "- [x] alpha\n- [x] beta\n")
        }

        let second = MarkdownTasks.toggleEdit(forTaskAt: 1, in: source)
        #expect(second?.replacement == " ")
    }

    @Test func outOfRangeIndexIsNil() {
        #expect(MarkdownTasks.toggleEdit(forTaskAt: 5, in: "- [ ] only") == nil)
        #expect(MarkdownTasks.toggleEdit(forTaskAt: -1, in: "- [ ] only") == nil)
    }

    @Test func rendererAndTogglerAgreeOnIndexing() {
        let source = """
        - [ ] one

        Some text.

        1. [x] two
        """
        let html = MarkdownHTMLRenderer().renderBody(source)
        let markers = MarkdownTasks.markers(in: source)
        // Both walk top-to-bottom; index N in HTML must match marker N.
        #expect(markers.count == 2)
        #expect(html.contains("data-task-index=\"0\""))
        #expect(html.contains("data-task-index=\"1\" checked"))
    }
}

@Suite("Asset store")
struct AssetStoreTests {
    @Test func writesCollisionSafeNames() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashtyn-assets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date(timeIntervalSince1970: 1_753_900_000)
        let first = try AssetStore.writeImage(Data([1]), fileExtension: "png", assetsDirectory: dir, now: now)
        let second = try AssetStore.writeImage(Data([2]), fileExtension: "png", assetsDirectory: dir, now: now)
        #expect(first != second)
        #expect(first.lastPathComponent.hasPrefix("image-"))
        #expect(first.pathExtension == "png")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func relativePathsFromNoteToAsset() {
        let root = URL(fileURLWithPath: "/tmp/lib")
        #expect(
            AssetStore.relativePath(
                from: root, to: root.appendingPathComponent("Assets/cat.png")
            ) == "Assets/cat.png"
        )
        #expect(
            AssetStore.relativePath(
                from: root.appendingPathComponent("notes/deep"),
                to: root.appendingPathComponent("Assets/cat.png")
            ) == "../../Assets/cat.png"
        )
    }
}
