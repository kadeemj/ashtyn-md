import SwiftUI
import Combine

enum WindowID {
    static let standaloneDocument = "standalone-document"
}

/// Routes file-open events from the system (Finder, `open`, drag to Dock)
/// to whichever library window is active.
@MainActor
final class StandaloneOpenRequests {
    static let shared = StandaloneOpenRequests()
    let requests = PassthroughSubject<URL, Never>()
}

/// A single document opened outside any library. The file is edited in place
/// and never imported.
struct StandaloneDocumentView: View {
    let url: URL?

    @State private var session: DocumentSession?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let session {
                EditorContainerView(
                    session: session,
                    previewContext: standaloneContext(for: session)
                )
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn’t Open File",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .task(id: url) {
            guard let url, session == nil else { return }
            do {
                let opened = try await DocumentSession.open(
                    fileURL: url, recoveryStore: .standalone
                )
                SessionRegistry.shared.register(opened)
                session = opened
            } catch {
                loadError = error.localizedDescription
            }
        }
        .onDisappear {
            guard let session else { return }
            Task {
                await session.save(reason: .losingFocus)
                session.close()
                SessionRegistry.shared.unregister(session)
            }
        }
    }

    /// Standalone documents preview against their own folder; the Assets
    /// folder is created next to the file, after asking once.
    private func standaloneContext(for session: DocumentSession) -> PreviewContext {
        let noteDirectory = session.fileURL.deletingLastPathComponent()
        return PreviewContext(
            assetRoot: noteDirectory,
            noteDirectoryRelativePath: "",
            assetsDirectory: { Self.consentedAssetsDirectory(nextTo: session.fileURL) },
            allowRawHTML: false,
            openDocumentLink: { url in
                let relative = (url.path.removingPercentEncoding ?? url.path).drop(while: { $0 == "/" })
                let target = noteDirectory.appendingPathComponent(String(relative))
                guard LibraryBrowser.isSupportedTextFile(target),
                      FileManager.default.fileExists(atPath: target.path) else { return }
                StandaloneOpenRequests.shared.requests.send(target)
            }
        )
    }

    /// Asks once per folder before creating an adjacent Assets directory for
    /// a standalone Markdown file; remembers the answer.
    @MainActor
    private static func consentedAssetsDirectory(nextTo fileURL: URL) -> URL? {
        let directory = fileURL.deletingLastPathComponent()
        let key = "standaloneAssetsConsent.\(AppSupportPaths.canonicalPath(of: directory))"
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            let alert = NSAlert()
            alert.messageText = "Create an “Assets” folder?"
            alert.informativeText = "Ashtyn MD stores pasted images in an Assets folder next to “\(fileURL.lastPathComponent)”."
            alert.addButton(withTitle: "Create Folder")
            alert.addButton(withTitle: "Don’t Create")
            defaults.set(alert.runModal() == .alertFirstButtonReturn, forKey: key)
        }
        return defaults.bool(forKey: key)
            ? directory.appendingPathComponent("Assets", isDirectory: true)
            : nil
    }
}
