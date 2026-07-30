import SwiftUI
import WebKit

/// WKWebView-backed Markdown preview. Receives pre-rendered body HTML and
/// handles link policy, task-checkbox clicks, and scroll persistence.
struct MarkdownPreviewView: NSViewRepresentable {
    let session: DocumentSession
    /// Root the ashtyn-file: scheme may serve from.
    let assetRoot: URL
    /// Directory of the note relative to `assetRoot`, used as the base path
    /// so relative links and images resolve correctly.
    let noteDirectoryRelativePath: String
    /// Pre-rendered body HTML (renderer runs off the main actor upstream).
    let bodyHTML: String
    /// Opens a document link inside Ashtyn MD.
    let openDocumentLink: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, openDocumentLink: openDocumentLink)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            PreviewAssetSchemeHandler(rootDirectory: assetRoot),
            forURLScheme: PreviewAssetSchemeHandler.scheme
        )
        let controller = configuration.userContentController
        controller.add(context.coordinator, name: "taskToggle")
        controller.add(context.coordinator, name: "scrollChanged")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.session = session
        guard context.coordinator.loadedHTML != bodyHTML else { return }
        context.coordinator.loadedHTML = bodyHTML
        let page = MarkdownPreviewPage.wrap(
            bodyHTML: bodyHTML,
            restoreScrollY: session.viewState.previewScrollOffset
        )
        let base = URL(
            string: "\(PreviewAssetSchemeHandler.scheme):///\(noteDirectoryRelativePath.isEmpty ? "" : noteDirectoryRelativePath + "/")"
        )
        webView.loadHTMLString(page, baseURL: base)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var session: DocumentSession
        weak var webView: WKWebView?
        var loadedHTML: String?
        private let openDocumentLink: (URL) -> Void

        init(session: DocumentSession, openDocumentLink: @escaping (URL) -> Void) {
            self.session = session
            self.openDocumentLink = openDocumentLink
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            MainActor.assumeIsolated {
                guard navigationAction.navigationType == .linkActivated,
                      let url = navigationAction.request.url else {
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
                switch url.scheme?.lowercased() {
                case "http", "https", "mailto":
                    // Web links open in the default browser.
                    NSWorkspace.shared.open(url)
                case PreviewAssetSchemeHandler.scheme:
                    // Relative document link, resolved against the base path.
                    self.openDocumentLink(url)
                default:
                    break
                }
            }
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            let name = message.name
            let body = message.body
            MainActor.assumeIsolated {
                switch name {
                case "taskToggle":
                    guard let index = body as? Int else { return }
                    self.toggleTask(at: index)
                case "scrollChanged":
                    guard let y = body as? Double else { return }
                    self.session.viewState.previewScrollOffset = y
                default:
                    break
                }
            }
        }

        private func toggleTask(at index: Int) {
            guard let edit = MarkdownTasks.toggleEdit(forTaskAt: index, in: session.text) else { return }
            session.performSourceEdit(range: edit.range, replacement: edit.replacement)
        }
    }
}

/// Full-page wrapper: CSS, scroll restoration, task-checkbox and scroll
/// reporting scripts. No external resources — everything is inline.
enum MarkdownPreviewPage {
    static func wrap(bodyHTML: String, restoreScrollY: Double) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(css)</style>
        </head>
        <body>
        <main>\(bodyHTML)</main>
        <script>
        (function() {
            window.scrollTo(0, \(max(0, restoreScrollY)));
            let scrollTimer = null;
            addEventListener("scroll", function() {
                if (scrollTimer) { return; }
                scrollTimer = setTimeout(function() {
                    scrollTimer = null;
                    window.webkit.messageHandlers.scrollChanged.postMessage(window.scrollY);
                }, 150);
            }, { passive: true });
            document.addEventListener("click", function(event) {
                const target = event.target;
                if (target && target.matches && target.matches("input[data-task-index]")) {
                    event.preventDefault();
                    window.webkit.messageHandlers.taskToggle.postMessage(
                        parseInt(target.getAttribute("data-task-index"), 10)
                    );
                }
            });
        })();
        </script>
        </body>
        </html>
        """
    }

    static let css = """
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; }
    body {
        margin: 0;
        font: -apple-system-body;
        font-family: -apple-system, system-ui, sans-serif;
        font-size: 15px;
        line-height: 1.6;
        color: light-dark(#1d1d1f, #e8e8ed);
        background: transparent;
    }
    main { max-width: 760px; margin: 0 auto; padding: 24px 32px 64px; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; font-weight: 650; }
    h1 { font-size: 1.9em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
    h1:first-child { margin-top: 0.2em; }
    p { margin: 0.6em 0; }
    a { color: light-dark(#0969da, #6ea8fe); text-decoration: none; }
    a:hover { text-decoration: underline; }
    code {
        font-family: ui-monospace, "SF Mono", Menlo, monospace;
        font-size: 0.88em;
        background: light-dark(rgba(0,0,0,0.055), rgba(255,255,255,0.1));
        border-radius: 4px;
        padding: 0.12em 0.35em;
    }
    pre {
        background: light-dark(rgba(0,0,0,0.045), rgba(255,255,255,0.07));
        border-radius: 8px;
        padding: 12px 14px;
        overflow-x: auto;
    }
    pre code { background: none; padding: 0; font-size: 0.85em; }
    blockquote {
        margin: 0.8em 0;
        padding: 0.1em 1em;
        border-left: 3px solid light-dark(#d0d7de, #4a4a4f);
        color: light-dark(#57606a, #a0a0a8);
    }
    ul, ol { padding-left: 1.6em; }
    ul.task-list { list-style: none; padding-left: 0.4em; }
    li.task { margin: 0.15em 0; }
    li.task input[type="checkbox"] { margin-right: 0.5em; vertical-align: -0.12em; }
    li.task > p { display: inline; margin: 0; }
    table { border-collapse: collapse; margin: 1em 0; display: block; overflow-x: auto; }
    th, td { border: 1px solid light-dark(#d0d7de, #4a4a4f); padding: 6px 12px; }
    th { background: light-dark(rgba(0,0,0,0.03), rgba(255,255,255,0.06)); }
    img { max-width: 100%; border-radius: 4px; }
    hr { border: none; border-top: 1px solid light-dark(#d0d7de, #4a4a4f); margin: 1.6em 0; }
    .blocked-image {
        display: inline-block;
        padding: 0.2em 0.6em;
        border: 1px dashed light-dark(#d0d7de, #4a4a4f);
        border-radius: 6px;
        color: light-dark(#57606a, #a0a0a8);
        font-size: 0.9em;
    }
    """
}
