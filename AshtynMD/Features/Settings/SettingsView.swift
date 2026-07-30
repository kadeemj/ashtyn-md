import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            EditorSettingsView()
                .tabItem { Label("Editor", systemImage: "square.and.pencil") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 560)
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

        DisclosureGroup("Token Colors") {
            tokenColorEditor(for: language, profile: binding)
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
                            ?? themePalette[token]
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
