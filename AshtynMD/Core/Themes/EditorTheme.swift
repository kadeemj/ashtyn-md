import AppKit

/// A named pair of token palettes. "System" follows the window appearance;
/// Light and Dark force one palette regardless of appearance.
struct EditorTheme: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var lightPalette: [SyntaxToken: CodableColor]
    var darkPalette: [SyntaxToken: CodableColor]
    /// nil follows the system appearance.
    var forcedAppearance: ForcedAppearance?

    enum ForcedAppearance: String, Codable, Sendable {
        case light
        case dark
    }

    func palette(forDarkAppearance isDark: Bool) -> [SyntaxToken: CodableColor] {
        switch forcedAppearance {
        case .light: return lightPalette
        case .dark: return darkPalette
        case nil: return isDark ? darkPalette : lightPalette
        }
    }

    // MARK: - Built-in themes

    private static let defaultLight: [SyntaxToken: CodableColor] = [
        .keyword: CodableColor(red: 0.61, green: 0.14, blue: 0.58),
        .string: CodableColor(red: 0.77, green: 0.10, blue: 0.09),
        .number: CodableColor(red: 0.11, green: 0.00, blue: 0.81),
        .comment: CodableColor(red: 0.00, green: 0.46, blue: 0.00),
        .type: CodableColor(red: 0.22, green: 0.00, blue: 0.63),
        .function: CodableColor(red: 0.20, green: 0.43, blue: 0.45),
        .variable: CodableColor(red: 0.05, green: 0.05, blue: 0.05),
        .property: CodableColor(red: 0.20, green: 0.43, blue: 0.45),
        .operator: CodableColor(red: 0.20, green: 0.20, blue: 0.20),
        .punctuation: CodableColor(red: 0.35, green: 0.35, blue: 0.35),
        .markupHeading: CodableColor(red: 0.04, green: 0.31, blue: 0.47),
        .markupEmphasis: CodableColor(red: 0.61, green: 0.14, blue: 0.58),
        .markupLink: CodableColor(red: 0.09, green: 0.29, blue: 0.79),
        .markupCode: CodableColor(red: 0.77, green: 0.10, blue: 0.09),
    ]

    private static let defaultDark: [SyntaxToken: CodableColor] = [
        .keyword: CodableColor(red: 0.99, green: 0.37, blue: 0.64),
        .string: CodableColor(red: 0.99, green: 0.42, blue: 0.37),
        .number: CodableColor(red: 0.82, green: 0.75, blue: 0.41),
        .comment: CodableColor(red: 0.42, green: 0.47, blue: 0.53),
        .type: CodableColor(red: 0.36, green: 0.85, blue: 1.00),
        .function: CodableColor(red: 0.40, green: 0.72, blue: 0.64),
        .variable: CodableColor(red: 0.90, green: 0.90, blue: 0.90),
        .property: CodableColor(red: 0.40, green: 0.72, blue: 0.64),
        .operator: CodableColor(red: 0.80, green: 0.80, blue: 0.80),
        .punctuation: CodableColor(red: 0.65, green: 0.65, blue: 0.65),
        .markupHeading: CodableColor(red: 0.36, green: 0.85, blue: 1.00),
        .markupEmphasis: CodableColor(red: 0.99, green: 0.37, blue: 0.64),
        .markupLink: CodableColor(red: 0.40, green: 0.60, blue: 1.00),
        .markupCode: CodableColor(red: 0.63, green: 0.40, blue: 0.90),
    ]

    static let system = EditorTheme(
        id: "system", name: "System",
        lightPalette: defaultLight, darkPalette: defaultDark,
        forcedAppearance: nil
    )
    static let light = EditorTheme(
        id: "light", name: "Light",
        lightPalette: defaultLight, darkPalette: defaultDark,
        forcedAppearance: .light
    )
    static let dark = EditorTheme(
        id: "dark", name: "Dark",
        lightPalette: defaultLight, darkPalette: defaultDark,
        forcedAppearance: .dark
    )

    static let builtIn: [EditorTheme] = [.system, .light, .dark]

    static func theme(withID id: String) -> EditorTheme {
        builtIn.first { $0.id == id } ?? .system
    }
}

extension CodableColor {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    init(nsColor: NSColor) {
        let converted = nsColor.usingColorSpace(.sRGB) ?? .black
        self.init(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
    }
}
