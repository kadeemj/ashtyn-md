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
                // ⌘N always captures to the Inbox, whatever is selected.
                Button("New Note") {
                    appModel.actions.newNoteInInbox()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appModel.libraryRoot == nil)

                Button("New Note in Selected Location") {
                    appModel.actions.newNoteInSelectedLocation(
                        selection: appModel.sidebarSelection
                    )
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(appModel.libraryRoot == nil)

                Menu("New Code File") {
                    ForEach(newCodeFileLanguages, id: \.self) { language in
                        let definition = LanguageDefinition.definition(for: language)
                        Button("\(definition.displayName) (.\(definition.preferredExtension))") {
                            appModel.actions.newNoteInSelectedLocation(
                                language: language,
                                selection: appModel.sidebarSelection
                            )
                        }
                    }
                }
                .disabled(appModel.libraryRoot == nil)

                Button("New Folder") {
                    appModel.actions.newFolder(
                        named: "New Folder", selection: appModel.sidebarSelection
                    )
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
                    if let active = appModel.tabs.activeTabID {
                        appModel.tabs.close(active)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appModel.tabs.activeTabID == nil)

                Divider()

                // ⌘M is system Minimize, so filing takes ⌃⌘M.
                Button("Move to…") {
                    LibraryCommandRequests.shared.send(.moveToFolder)
                }
                .keyboardShortcut("m", modifiers: [.command, .control])
                .disabled(appModel.libraryRoot == nil)
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
            CommandMenu("Format") {
                Group {
                    Button("Bold") { sendToEditor(#selector(PlainTextView.toggleMarkdownBold(_:))) }
                        .keyboardShortcut("b", modifiers: .command)
                    Button("Italic") { sendToEditor(#selector(PlainTextView.toggleMarkdownItalic(_:))) }
                        .keyboardShortcut("i", modifiers: .command)
                    // ⌘E is taken by "Use Selection for Find" from the find bar.
                    Button("Code") { sendToEditor(#selector(PlainTextView.toggleMarkdownInlineCode(_:))) }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                    Button("Strikethrough") {
                        sendToEditor(#selector(PlainTextView.toggleMarkdownStrikethrough(_:)))
                    }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                    Button("Link…") { sendToEditor(#selector(PlainTextView.insertMarkdownLink(_:))) }
                        .keyboardShortcut("k", modifiers: .command)
                }
                .disabled(!isMarkdownActive)

                Divider()

                // Reserves ⌘1–⌘6 app-wide; tab switching must not claim them.
                Group {
                    Button("Heading 1") { sendToEditor(#selector(PlainTextView.setMarkdownHeading1(_:))) }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("Heading 2") { sendToEditor(#selector(PlainTextView.setMarkdownHeading2(_:))) }
                        .keyboardShortcut("2", modifiers: .command)
                    Button("Heading 3") { sendToEditor(#selector(PlainTextView.setMarkdownHeading3(_:))) }
                        .keyboardShortcut("3", modifiers: .command)
                    Button("Heading 4") { sendToEditor(#selector(PlainTextView.setMarkdownHeading4(_:))) }
                        .keyboardShortcut("4", modifiers: .command)
                    Button("Heading 5") { sendToEditor(#selector(PlainTextView.setMarkdownHeading5(_:))) }
                        .keyboardShortcut("5", modifiers: .command)
                    Button("Heading 6") { sendToEditor(#selector(PlainTextView.setMarkdownHeading6(_:))) }
                        .keyboardShortcut("6", modifiers: .command)
                    Button("Body Text") {
                        sendToEditor(#selector(PlainTextView.clearMarkdownBlockStyle(_:)))
                    }
                    .keyboardShortcut("0", modifiers: .command)
                }
                .disabled(!isMarkdownActive)

                Divider()

                Group {
                    Button("Quote") { sendToEditor(#selector(PlainTextView.toggleMarkdownQuote(_:))) }
                        .keyboardShortcut("u", modifiers: [.command, .shift])
                    Button("Bulleted List") {
                        sendToEditor(#selector(PlainTextView.toggleMarkdownBulletList(_:)))
                    }
                    .keyboardShortcut("8", modifiers: [.command, .shift])
                    Button("Numbered List") {
                        sendToEditor(#selector(PlainTextView.toggleMarkdownNumberedList(_:)))
                    }
                    .keyboardShortcut("7", modifiers: [.command, .shift])
                    // ⇧⌘C is the system color panel, so Todo takes ⇧⌘L.
                    Button("Todo") { sendToEditor(#selector(PlainTextView.toggleMarkdownTask(_:))) }
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                    Button("Divider") {
                        sendToEditor(#selector(PlainTextView.insertMarkdownDivider(_:)))
                    }
                    .keyboardShortcut("-", modifiers: [.command, .shift])
                }
                .disabled(!isMarkdownActive)
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Line Wrap") { sendToEditor(#selector(PlainTextView.toggleLineWrap(_:))) }
                    .keyboardShortcut("l", modifiers: [.command, .option])

                Toggle("Allow Raw HTML in Preview", isOn: Binding(
                    get: { appModel.allowRawHTML },
                    set: { appModel.allowRawHTML = $0 }
                ))
                .disabled(appModel.libraryRoot == nil)

                Divider()

                Button("Editor Mode") {
                    appModel.activeSession?.requestPreviewMode("editor")
                }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(appModel.activeSession?.languageID != .markdown)

                Button("Split Mode") {
                    appModel.activeSession?.requestPreviewMode("split")
                }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(appModel.activeSession?.languageID != .markdown)

                Button("Preview Mode") {
                    appModel.activeSession?.requestPreviewMode("preview")
                }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(appModel.activeSession?.languageID != .markdown)

                Divider()

                // Extends the ⌥⌘1/2/3 view cluster. ⌃⌘F, ⌥⌘F, and ⌥⌘M are all
                // system-bound, which is why focus mode is not on an "F".
                Button("Focus Mode") { sendToEditor(#selector(PlainTextView.toggleFocusMode(_:))) }
                    .keyboardShortcut("4", modifiers: [.command, .option])
                    .disabled(!isMarkdownActive)
                Button("Typewriter Mode") {
                    sendToEditor(#selector(PlainTextView.toggleTypewriterMode(_:)))
                }
                .keyboardShortcut("5", modifiers: [.command, .option])
                .disabled(!isMarkdownActive)
                Button("Show Markdown Markers") {
                    sendToEditor(#selector(PlainTextView.cycleMarkerVisibility(_:)))
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(!isMarkdownActive)

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

    /// Whether the focused document is Markdown. Formatting commands are
    /// disabled otherwise; the selectors guard again, because sendToEditor
    /// walks the responder chain and can reach a code editor in another window.
    private var isMarkdownActive: Bool {
        appModel.activeSession?.languageID == .markdown
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
