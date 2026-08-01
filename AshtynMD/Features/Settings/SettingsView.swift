import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        TabView {
            EditorSettingsView()
                .tabItem { Label("Editor", systemImage: "square.and.pencil") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
        }
        .frame(width: 520, height: 560)
    }
}

struct LibrarySettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel
        Form {
            Section("Current Library") {
                Toggle(
                    "Rename files to match the first line",
                    isOn: $model.titleRenameEnabled
                )
                .disabled(appModel.libraryRoot == nil)
                .help("When enabled, Markdown note filenames follow their first line after a short pause.")

                if appModel.libraryRoot == nil {
                    Text("Choose a library to configure its note behavior.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct EditorSettingsView: View {
    private var store = EditorProfilesStore.shared
    @State private var selectedLanguage: LanguageID = .markdown

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("Theme", selection: $store.themeID) {
                    ForEach(EditorTheme.builtIn) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .help("System follows the window appearance; Light and Dark force one palette.")
            }

            Section("Per-Language Appearance") {
                Picker("Language", selection: $selectedLanguage) {
                    ForEach(LanguageID.allCases) { language in
                        Text(LanguageDefinition.definition(for: language).displayName)
                            .tag(language)
                    }
                }

                profileEditor(for: selectedLanguage)
            }

            Section {
                HStack {
                    Button("Reset \(LanguageDefinition.definition(for: selectedLanguage).displayName)") {
                        store.reset(selectedLanguage)
                    }
                    Spacer()
                    Button("Reset All Languages", role: .destructive) {
                        store.resetAll()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func profileEditor(for language: LanguageID) -> some View {
        let binding = Binding(
            get: { store.profile(for: language) },
            set: { store.update($0, for: language) }
        )

        TextField("Font Family", text: binding.fontFamily)
        HStack {
            Text("Font Size")
            Spacer()
            Stepper(
                value: binding.fontSize, in: 9...32, step: 1
            ) {
                Text("\(binding.wrappedValue.fontSize, format: .number) pt")
                    .monospacedDigit()
            }
        }
        HStack {
            Text("Line Height")
            Spacer()
            Stepper(
                value: binding.lineHeightMultiple, in: 1.0...2.5, step: 0.05
            ) {
                Text("\(binding.wrappedValue.lineHeightMultiple, format: .number.precision(.fractionLength(2)))×")
                    .monospacedDigit()
            }
        }
        HStack {
            Text("Tab Width")
            Spacer()
            Stepper(value: binding.tabWidth, in: 1...8) {
                Text("\(binding.wrappedValue.tabWidth) spaces")
                    .monospacedDigit()
            }
        }
        Toggle("Indent with Tabs", isOn: binding.usesTabs)
        Toggle("Wrap Lines", isOn: binding.wrapsLines)

        if language == .markdown {
            DisclosureGroup("Markdown Presentation") {
                markdownEditor(profile: binding)
            }
        }

        DisclosureGroup("Token Colors") {
            tokenColorEditor(for: language, profile: binding)
        }
    }

    /// Options that only mean anything for a prose document.
    @ViewBuilder
    private func markdownEditor(profile: Binding<EditorProfile>) -> some View {
        TextField("Code Font Family", text: profile.monospaceFontFamily)
            .help("Used for code spans and fenced blocks inside a note.")

        Picker("Markdown Markers", selection: profile.markerVisibility) {
            Text("Always Visible").tag(MarkerVisibility.always)
            Text("Reveal on Caret Line").tag(MarkerVisibility.caretLine)
            Text("Hidden").tag(MarkerVisibility.hidden)
        }
        .help("Whether the **, #, and []() characters are dimmed or shown.")

        Toggle("Show Tags as Pills", isOn: profile.rendersTagPills)
        Toggle("Focus Mode", isOn: profile.focusModeEnabled)
            .help("Dims every paragraph except the one holding the caret.")
        Toggle("Typewriter Mode", isOn: profile.typewriterModeEnabled)
            .help("Keeps the caret line vertically centered while typing.")

        HStack {
            Text("Paragraph Spacing")
            Spacer()
            Stepper(value: profile.paragraphSpacing, in: 0...24, step: 1) {
                Text("\(profile.wrappedValue.paragraphSpacing, format: .number) pt")
                    .monospacedDigit()
            }
        }

        DisclosureGroup("Heading Sizes") {
            ForEach(Array(profile.wrappedValue.headingScales.indices), id: \.self) { index in
                HStack {
                    Text("Heading \(index + 1)")
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { profile.wrappedValue.headingScales[index] },
                            set: { newValue in
                                var updated = profile.wrappedValue
                                updated.headingScales[index] = newValue
                                profile.wrappedValue = updated
                            }
                        ),
                        in: 1.0...3.0,
                        step: 0.05
                    ) {
                        let scale = profile.wrappedValue.headingScales[index]
                        Text("\(scale, format: .number.precision(.fractionLength(2)))×")
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tokenColorEditor(
        for language: LanguageID, profile: Binding<EditorProfile>
    ) -> some View {
        let isDark = NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let themePalette = store.theme.palette(forDarkAppearance: isDark)

        ForEach(SyntaxToken.allCases, id: \.self) { token in
            ColorPicker(
                tokenDisplayName(token),
                selection: Binding(
                    get: {
                        let color = profile.wrappedValue.tokenColors[token]
                            ?? themePalette.tokens[token]
                            ?? CodableColor(nsColor: .textColor)
                        return Color(nsColor: color.nsColor)
                    },
                    set: { newColor in
                        var updated = profile.wrappedValue
                        updated.tokenColors[token] = CodableColor(nsColor: NSColor(newColor))
                        profile.wrappedValue = updated
                    }
                ),
                supportsOpacity: false
            )
        }
        Button("Clear Color Overrides") {
            var updated = profile.wrappedValue
            updated.tokenColors = [:]
            profile.wrappedValue = updated
        }
    }

    private func tokenDisplayName(_ token: SyntaxToken) -> String {
        switch token {
        case .keyword: return "Keywords"
        case .string: return "Strings"
        case .number: return "Numbers"
        case .comment: return "Comments"
        case .type: return "Types"
        case .function: return "Functions"
        case .variable: return "Variables"
        case .property: return "Properties"
        case .operator: return "Operators"
        case .punctuation: return "Punctuation"
        case .markupHeading: return "Markdown Headings"
        case .markupEmphasis: return "Markdown Emphasis"
        case .markupLink: return "Markdown Links"
        case .markupCode: return "Markdown Code"
        }
    }
}
