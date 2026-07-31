import AppKit
import Foundation
import Testing

@testable import AshtynMD

@Suite("Editor themes and profiles")
struct EditorThemeTests {
    // MARK: - Built-in themes

    @Test("every built-in theme has a distinct palette")
    func builtInThemesAreDistinct() {
        // Before Phase 7 all three built-ins shared one pair of palettes and
        // only differed by forcedAppearance, which made the theme picker a
        // glorified appearance switch. This is the regression guard.
        let palettes = EditorTheme.builtIn.map { $0.palette(forDarkAppearance: false) }
        for (index, palette) in palettes.enumerated() {
            for other in palettes[(index + 1)...] {
                #expect(
                    palette.background != other.background || palette.accent != other.accent,
                    "two built-in themes share a background and accent"
                )
            }
        }
        #expect(EditorTheme.builtIn.count >= 4)
    }

    @Test("the light and dark theme ids survive so stored preferences keep working")
    func legacyThemeIDs() {
        #expect(EditorTheme.theme(withID: "light").forcedAppearance == .light)
        #expect(EditorTheme.theme(withID: "dark").forcedAppearance == .dark)
        #expect(EditorTheme.theme(withID: "system").forcedAppearance == nil)
        #expect(EditorTheme.theme(withID: "nonsense").id == "system")
    }

    @Test("a forced theme ignores the ambient appearance")
    func forcedAppearanceWins() {
        let dark = EditorTheme.theme(withID: "dark")
        #expect(dark.palette(forDarkAppearance: false) == dark.palette(forDarkAppearance: true))

        let system = EditorTheme.theme(withID: "system")
        #expect(system.palette(forDarkAppearance: false) != system.palette(forDarkAppearance: true))
    }

    @Test("every palette defines every syntax token")
    func palettesAreComplete() {
        for theme in EditorTheme.builtIn {
            for isDark in [true, false] {
                let palette = theme.palette(forDarkAppearance: isDark)
                for token in SyntaxToken.allCases {
                    #expect(palette.tokens[token] != nil, "\(theme.id) missing \(token)")
                }
            }
        }
    }

    @Test("every markdown role resolves to a color")
    func rolesResolve() {
        let palette = EditorTheme.theme(withID: "system").palette(forDarkAppearance: false)
        for role in MarkdownStyleRole.allCases {
            _ = palette.color(for: role)
        }
    }

    // MARK: - Profile decoding

    @Test("a version 1 profile decodes with defaults for the new fields")
    func decodesLegacyProfile() throws {
        // Swift's synthesized init(from:) throws keyNotFound for absent keys
        // rather than applying property defaults, so EditorProfile hand-writes
        // one. This is the literal shape written by the shipped app.
        let json = """
        {
          "fontFamily": "SF Mono",
          "fontSize": 15,
          "lineHeightMultiple": 1.45,
          "tabWidth": 4,
          "usesTabs": false,
          "wrapsLines": true,
          "tokenColors": []
        }
        """
        let profile = try JSONDecoder().decode(EditorProfile.self, from: Data(json.utf8))
        #expect(profile.fontFamily == "SF Mono")
        #expect(profile.fontSize == 15)
        #expect(profile.markerVisibility == .caretLine)
        #expect(profile.rendersTagPills)
        #expect(profile.headingScales.count == 6)
        #expect(profile.focusModeEnabled == false)
        #expect(profile.typewriterModeEnabled == false)
        #expect(profile.monospaceFontFamily.isEmpty == false)
    }

    @Test("a profile round-trips through JSON")
    func profileRoundTrip() throws {
        var profile = EditorProfile.defaultProfile(for: .markdown)
        profile.tokenColors[.keyword] = CodableColor(red: 0.1, green: 0.2, blue: 0.3)
        profile.roleStyles[.heading] = MarkdownRoleStyle(sizeMultiple: 2, weight: .bold)
        profile.markerVisibility = .hidden
        profile.contentWidthLimit = 720

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(EditorProfile.self, from: data)
        #expect(decoded == profile)
    }

    @Test("enum-keyed dictionaries round-trip even though they encode as arrays")
    func enumKeyedDictionaryRoundTrip() throws {
        // [SyntaxToken: CodableColor] encodes as a flat JSON array because a
        // String-raw-value enum is not CodingKeyRepresentable. That is fine and
        // stable — this test exists so nobody "fixes" it into a breaking change.
        var profile = EditorProfile.defaultProfile(for: .swift)
        profile.tokenColors[.comment] = CodableColor(red: 1, green: 0, blue: 0)
        let data = try JSONEncoder().encode(profile)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["tokenColors"] is [Any])
        let decoded = try JSONDecoder().decode(EditorProfile.self, from: data)
        #expect(decoded.tokenColors[.comment] == CodableColor(red: 1, green: 0, blue: 0))
    }

    @Test("markdown defaults to a proportional body font and monospace code")
    func markdownDefaults() {
        let markdown = EditorProfile.defaultProfile(for: .markdown)
        #expect(markdown.wrapsLines)
        #expect(markdown.fontFamily != markdown.monospaceFontFamily)

        let swift = EditorProfile.defaultProfile(for: .swift)
        #expect(swift.fontFamily == swift.monospaceFontFamily)
    }

    @Test("heading scales descend")
    func headingScalesDescend() {
        let scales = EditorProfile.defaultProfile(for: .markdown).headingScales
        #expect(scales.count == 6)
        for index in 1..<scales.count {
            #expect(scales[index] <= scales[index - 1])
        }
        #expect(scales[0] > 1)
    }

    // MARK: - Role styles

    @Test("standard role styles describe the Bear-like look")
    func standardRoleStyles() {
        #expect(MarkdownRoleStyle.standard(for: .heading).weight == .bold)
        #expect(MarkdownRoleStyle.standard(for: .bold).weight == .bold)
        #expect(MarkdownRoleStyle.standard(for: .italic).isItalic)
        #expect(MarkdownRoleStyle.standard(for: .boldItalic).isItalic)
        #expect(MarkdownRoleStyle.standard(for: .boldItalic).weight == .bold)
        #expect(MarkdownRoleStyle.standard(for: .inlineCode).isMonospaced)
        #expect(MarkdownRoleStyle.standard(for: .codeBlock).isMonospaced)
        #expect(MarkdownRoleStyle.standard(for: .tag).weight == .semibold)
        // Markers stay the body font so revealing them cannot reflow the line.
        #expect(MarkdownRoleStyle.standard(for: .emphasisMarker).sizeMultiple == 1)
    }

    @Test("marker visibility defaults to revealing on the caret line")
    func markerVisibilityDefault() {
        #expect(EditorProfile.defaultProfile(for: .markdown).markerVisibility == .caretLine)
        #expect(MarkerVisibility.allCases.count == 3)
    }

    @Test("font weights map onto AppKit weights")
    func fontWeights() {
        #expect(MarkdownFontWeight.regular.nsWeight == .regular)
        #expect(MarkdownFontWeight.bold.nsWeight == .bold)
        #expect(MarkdownFontWeight.semibold.nsWeight == .semibold)
    }

    // MARK: - Store

    @MainActor
    @Test("the store persists and reloads the new fields")
    func storeRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorThemeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")

        let store = EditorProfilesStore(fileURL: file)
        var profile = store.profile(for: .markdown)
        profile.markerVisibility = .always
        profile.focusModeEnabled = true
        store.update(profile, for: .markdown)
        store.themeID = "slate"

        let reloaded = EditorProfilesStore(fileURL: file)
        #expect(reloaded.profile(for: .markdown).markerVisibility == .always)
        #expect(reloaded.profile(for: .markdown).focusModeEnabled)
        #expect(reloaded.themeID == "slate")
    }

    @MainActor
    @Test("a version 1 payload on disk still loads")
    func loadsVersionOnePayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorThemeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")

        let json = """
        {
          "version": 1,
          "themeID": "dark",
          "profiles": {
            "markdown": {
              "fontFamily": "Courier",
              "fontSize": 18,
              "lineHeightMultiple": 1.2,
              "tabWidth": 2,
              "usesTabs": true,
              "wrapsLines": false,
              "tokenColors": []
            }
          }
        }
        """
        try Data(json.utf8).write(to: file)

        let store = EditorProfilesStore(fileURL: file)
        #expect(store.themeID == "dark")
        #expect(store.profile(for: .markdown).fontFamily == "Courier")
        #expect(store.profile(for: .markdown).fontSize == 18)
        #expect(store.profile(for: .markdown).markerVisibility == .caretLine)
    }
}
