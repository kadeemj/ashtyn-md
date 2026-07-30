import WebKit
import UniformTypeIdentifiers

/// Serves local images to the preview through the restricted custom scheme
/// `ashtyn-file:`. Only files inside the configured root, with image
/// extensions, are ever readable; everything else 404s.
final class PreviewAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "ashtyn-file"

    /// Directory all served paths must stay inside (library root, or the
    /// note's folder for standalone documents).
    let rootDirectory: URL

    private static let allowedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg",
    ]
    private static let maximumFileSize = 32 * 1024 * 1024

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let data = serveData(for: url) else {
            urlSchemeTask.didFailWithError(CocoaError(.fileReadNoSuchFile))
            return
        }
        let mimeType = UTType(filenameExtension: url.pathExtension.lowercased())?
            .preferredMIMEType ?? "application/octet-stream"
        let response = URLResponse(
            url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func serveData(for url: URL) -> Data? {
        guard Self.allowedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let relativePath = url.path.removingPercentEncoding ?? url.path
        let candidate = rootDirectory.appendingPathComponent(relativePath)

        // Canonicalize and confine to the root: no "../" escapes, no symlink
        // detours outside the root.
        let canonicalRoot = AppSupportPaths.canonicalPath(of: rootDirectory)
        let canonicalTarget = AppSupportPaths.canonicalPath(of: candidate)
        guard canonicalTarget.hasPrefix(canonicalRoot + "/") else { return nil }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: canonicalTarget),
              let size = attributes[.size] as? Int, size <= Self.maximumFileSize else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: canonicalTarget))
    }
}
