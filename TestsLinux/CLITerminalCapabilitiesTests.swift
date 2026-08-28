import Foundation
import Testing
@testable import CodexBarCLI

struct CLITerminalCapabilitiesTests {
    @Test
    func `detects kitty graphics backend`() {
        let env = ["KITTY_WINDOW_ID": "1", "TERM": "xterm-kitty"]
        #expect(CLITerminalCapabilities.detect(environment: env) == .kittyGraphics)
        #expect(CLITerminalCapabilities.supportsEnhancedCards(useColor: true, environment: env))
    }

    @Test
    func `detects ghostty backend`() {
        let env = ["GHOSTTY_RESOURCES_DIR": "/usr/share/ghostty", "TERM": "xterm-ghostty"]
        #expect(CLITerminalCapabilities.detect(environment: env) == .kittyGraphics)
    }

    @Test
    func `detects truecolor without graphics env`() {
        let env = ["COLORTERM": "truecolor", "TERM": "alacritty"]
        #expect(CLITerminalCapabilities.detect(environment: env) == .truecolor)
    }

    @Test
    func `respects forced enhanced env override`() {
        let env = ["TERM": "dumb", "CODEXBAR_CARDS_ENHANCED": "1"]
        #expect(CLITerminalCapabilities.supportsEnhancedCards(useColor: true, environment: env))
    }

    @Test
    func `defaults cards to standard on plain ansi terminals`() {
        let env = ["TERM": "xterm-256color"]
        #expect(!CLITerminalCapabilities.supportsEnhancedCards(useColor: true, environment: env))
        #expect(!CLITerminalCapabilities.supportsEnhancedCards(useColor: false, environment: env))
    }

    @Test
    func `defaults cards to enhanced on truecolor terminals`() {
        let env = ["TERM": "xterm-256color", "COLORTERM": "truecolor"]
        #expect(CLITerminalCapabilities.supportsEnhancedCards(useColor: true, environment: env))
    }

    @Test
    func `respects forced enhanced opt out`() {
        let env = ["TERM": "xterm-256color", "CODEXBAR_CARDS_ENHANCED": "0"]
        #expect(!CLITerminalCapabilities.supportsEnhancedCards(useColor: true, environment: env))
    }
}
