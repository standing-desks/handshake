import Foundation

nonisolated struct CoreConfig: Decodable, Equatable, Sendable {
    let appearance: CoreAppearance
    let terminal: CoreTerminalConfig
    let editor: CoreEditorConfig

    init(appearance: CoreAppearance, terminal: CoreTerminalConfig, editor: CoreEditorConfig = .init()) {
        self.appearance = appearance
        self.terminal = terminal
        self.editor = editor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try container.decode(CoreAppearance.self, forKey: .appearance)
        terminal = try container.decode(CoreTerminalConfig.self, forKey: .terminal)
        editor = try container.decodeIfPresent(CoreEditorConfig.self, forKey: .editor) ?? .init()
    }

    private enum CodingKeys: String, CodingKey { case appearance, terminal, editor }

    enum ColorScheme: String, Decodable, Sendable {
        case system
        case light
        case dark
    }
}

nonisolated struct CoreEditorConfig: Decodable, Equatable, Sendable {
    let autosave: Bool
    let autosaveDelayMilliseconds: Int

    init(autosave: Bool = true, autosaveDelayMilliseconds: Int = 500) {
        self.autosave = autosave
        self.autosaveDelayMilliseconds = autosaveDelayMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case autosave
        case autosaveDelayMilliseconds = "autosave_delay_ms"
    }
}

nonisolated struct CoreTerminalConfig: Decodable, Equatable, Sendable {
    let fontFamily: String
    let fontSize: Double
    let cursorStyle: CursorStyle
    let cursorBlink: Bool
    let palettes: CoreTerminalPalettes?

    init(
        fontFamily: String, fontSize: Double, cursorStyle: CursorStyle = .block,
        cursorBlink: Bool = true, palettes: CoreTerminalPalettes? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.palettes = palettes
    }

    private enum CodingKeys: String, CodingKey {
        case fontFamily = "font_family"
        case fontSize = "font_size"
        case cursorStyle = "cursor_style"
        case cursorBlink = "cursor_blink"
        case palettes
    }

    enum CursorStyle: String, Decodable, Sendable {
        case block
        case underline
        case bar
    }
}

nonisolated struct CoreAppearance: Decodable, Equatable, Sendable {
    let colorScheme: CoreConfig.ColorScheme

    private enum CodingKeys: String, CodingKey {
        case colorScheme = "color_scheme"
    }
}

nonisolated struct CoreTerminalPalettes: Decodable, Equatable, Sendable {
    let light: CoreTerminalPalette
    let dark: CoreTerminalPalette
}

nonisolated struct CoreTerminalPalette: Decodable, Equatable, Sendable {
    let background: String
    let foreground: String
    let cursor: String
    let selection: String
    let ansi: [String]
}
