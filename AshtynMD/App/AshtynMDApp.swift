import SwiftUI

@main
struct AshtynMDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            LibraryWindowView()
                .environment(appModel)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Markdown File") {
                    appModel.newFile(language: .markdown)
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appModel.libraryRoot == nil)

                Menu("New Code File") {
                    ForEach(newCodeFileLanguages, id: \.self) { language in
                        let definition = LanguageDefinition.definition(for: language)
                        Button("\(definition.displayName) (.\(definition.preferredExtension))") {
                            appModel.newFile(language: language)
                        }
                    }
                }
                .disabled(appModel.libraryRoot == nil)

                Button("New Folder") {
                    appModel.newFolder(named: "New Folder")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(appModel.libraryRoot == nil)
            }
            CommandGroup(after: .saveItem) {
                Button("Save") {
                    SessionRegistry.shared.saveAll(reason: .explicit)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Close Tab") {
                    if let active = appModel.activeTabID {
                        appModel.closeTab(active)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appModel.activeTabID == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Search Library") {
                    appModel.sidebarSelection = .search
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(appModel.libraryRoot == nil)

                Divider()

                Button("Go to Line…") { sendToEditor(#selector(PlainTextView.goToLine(_:))) }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Duplicate Line") { sendToEditor(#selector(PlainTextView.duplicateLineOrSelection(_:))) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Delete Line") { sendToEditor(#selector(PlainTextView.deleteCurrentLines(_:))) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Move Line Up") { sendToEditor(#selector(PlainTextView.moveLinesUp(_:))) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Move Line Down") { sendToEditor(#selector(PlainTextView.moveLinesDown(_:))) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Toggle Comment") { sendToEditor(#selector(PlainTextView.toggleComment(_:))) }
                    .keyboardShortcut("/", modifiers: .command)

                Divider()

                Button("Indent") { sendToEditor(#selector(PlainTextView.indentSelection(_:))) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Outdent") { sendToEditor(#selector(PlainTextView.outdentSelection(_:))) }
                    .keyboardShortcut("[", modifiers: .command)

                Divider()

                Button("Complete") { sendToEditor(#selector(NSTextView.complete(_:))) }
                    .keyboardShortcut(" ", modifiers: .control)
                Button("AI Completion") { sendToEditor(#selector(PlainTextView.requestAICompletion(_:))) }
                    .keyboardShortcut(" ", modifiers: [.control, .option])
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Line Wrap") { sendToEditor(#selector(PlainTextView.toggleLineWrap(_:))) }
                    .keyboardShortcut("l", modifiers: [.command, .option])

                Toggle("Allow Raw HTML in Preview", isOn: Binding(
                    get: { appModel.allowRawHTML },
                    set: { appModel.allowRawHTML = $0 }
                ))
                .disabled(appModel.libraryRoot == nil)

                Menu("Language") {
                    Picker("Language", selection: languageOverrideBinding) {
                        Text("Automatic").tag(LanguageID?.none)
                        Divider()
                        ForEach(LanguageID.allCases) { language in
                            Text(LanguageDefinition.definition(for: language).displayName)
                                .tag(LanguageID?.some(language))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .disabled(appModel.activeSession == nil)
            }
        }

        WindowGroup(id: WindowID.standaloneDocument, for: URL.self) { $url in
            StandaloneDocumentView(url: url)
        }

        Settings {
            SettingsView()
        }
    }

    private var languageOverrideBinding: Binding<LanguageID?> {
        Binding(
            get: { appModel.activeSession?.languageOverride },
            set: { appModel.activeSession?.setLanguageOverride($0) }
        )
    }

    private var newCodeFileLanguages: [LanguageID] {
        [.plainText, .swift, .python, .javascript, .typescript, .json, .yaml, .html, .css, .shell]
    }

    /// Routes an editor command through the responder chain to the focused
    /// text view, exactly like a nib-defined menu item would.
    private func sendToEditor(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Instantiating the registry installs its activation observers.
        _ = SessionRegistry.shared
        #if DEBUG
        if UITestLaunchConfiguration.current.isEnabled,
           UITestLaunchConfiguration.current.opensStandalone,
           let url = try? UITestLaunchConfiguration.standaloneFixtureURL() {
            Task { @MainActor in
                await Task.yield()
                StandaloneOpenRequests.shared.requests.send(url)
            }
        }
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            StandaloneOpenRequests.shared.requests.send(url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SessionRegistry.shared.saveAllBlockingForTermination()
        return .terminateNow
    }
}
