import Foundation

enum CLITerminalBackend: Equatable, Sendable {
    case standard
    case truecolor
    case kittyGraphics
}

enum CLITerminalCapabilities {
    static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> CLITerminalBackend {
        if self.supportsKittyGraphics(environment: environment) {
            return .kittyGraphics
        }
        if self.supportsTruecolor(environment: environment) {
            return .truecolor
        }
        return .standard
    }

    static func supportsEnhancedCards(
        useColor: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        guard useColor else { return false }
        if environment["CODEXBAR_CARDS_ENHANCED"] == "1" { return true }
        if environment["CODEXBAR_CARDS_ENHANCED"] == "0" { return false }
        return self.supportsTruecolor(environment: environment)
    }

    static func supportsKittyGraphics(environment: [String: String]) -> Bool {
        if environment["KITTY_WINDOW_ID"] != nil { return true }
        if environment["GHOSTTY_RESOURCES_DIR"] != nil { return true }
        let term = environment["TERM"]?.lowercased() ?? ""
        if term.contains("kitty") || term.contains("ghostty") || term.contains("wezterm") {
            return true
        }
        return false
    }

    static func supportsTruecolor(environment: [String: String]) -> Bool {
        if self.supportsKittyGraphics(environment: environment) { return true }
        let colorTerm = environment["COLORTERM"]?.lowercased() ?? ""
        if colorTerm.contains("truecolor") || colorTerm.contains("24bit") { return true }
        let term = environment["TERM"]?.lowercased() ?? ""
        return term.contains("foot") || term.contains("alacritty")
    }
}
