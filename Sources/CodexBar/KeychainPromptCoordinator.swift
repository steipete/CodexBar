import AppKit
import CodexBarCore
import SweetCookieKit

enum KeychainPromptCoordinator {
    private static let promptLock = NSLock()

    static func install() {
        KeychainPromptHandler.handler = { context in
            self.presentKeychainPrompt(context)
        }
        BrowserCookieKeychainPromptHandler.handler = { context in
            self.presentBrowserCookiePrompt(context)
        }
    }

    private static func presentKeychainPrompt(_ context: KeychainPromptContext) {
        let (title, message) = self.keychainCopy(for: context)
        self.presentAlert(title: title, message: message)
    }

    private static func presentBrowserCookiePrompt(_ context: BrowserCookieKeychainPromptContext) {
        let title = "Keychain Access Required"
        let message = [
            "CodexBar will ask macOS Keychain for “\(context.label)” so it can decrypt browser cookies",
            "and authenticate your account. Click OK to continue.",
        ].joined(separator: " ")
        self.presentAlert(title: title, message: message)
    }

    private static func keychainCopy(for context: KeychainPromptContext) -> (title: String, message: String) {
        let title = "Keychain Access Required"
        switch context.kind {
        case .claudeOAuth:
            return (title, [
                "CodexBar will ask macOS Keychain for the Claude Code OAuth token",
                "so it can fetch your Claude usage. Click OK to continue.",
            ].joined(separator: " "))
        case .codexCookie:
            return (title, [
                "CodexBar will ask macOS Keychain for your OpenAI cookie header",
                "so it can fetch Codex dashboard extras. Click OK to continue.",
            ].joined(separator: " "))
        case .claudeCookie:
            return (title, [
                "CodexBar will ask macOS Keychain for your Claude cookie header",
                "so it can fetch Claude web usage. Click OK to continue.",
            ].joined(separator: " "))
        case .cursorCookie:
            return (title, [
                "CodexBar will ask macOS Keychain for your Cursor cookie header",
                "so it can fetch usage. Click OK to continue.",
            ].joined(separator: " "))
        case .opencodeCookie:
            return (title, [
                "CodexBar will ask macOS Keychain for your OpenCode cookie header",
                "so it can fetch usage. Click OK to continue.",
            ].joined(separator: " "))
        case .factoryCookie:
            return (title, [
                "CodexBar will ask macOS Keychain for your Factory cookie header",
                "so it can fetch usage. Click OK to continue.",
            ].joined(separator: " "))
        case .zaiToken:
            return (title, [
                "CodexBar will ask macOS Keychain for your z.ai API token",
                "so it can fetch usage. Click OK to continue.",
            ].joined(separator: " "))
        case .syntheticToken:
            return (title, [
                "CodexBar will ask macOS Keychain for your Synthetic API key",
                "so it can fetch usage. Click OK to continue.",
            ].joined(separator: " "))
        case .copilotToken:
            return (title, [
                "CodexBar will ask macOS Keychain for your GitHub Copilot token",
                "so it can fetch usage. Click OK to continue.",
            ].joined(separator: " "))
        case .kimiToken:
            return (title, [
                "CodexBar will ask macOS Keychain for your Kimi auth token",
                "so it can fetch usage. Click OK to continue.",
            ].joined(separator: " "))
        case .kimiK2Token:
            return (title, [
                "CodexBar will ask macOS Keychain for your Kimi K2 API key",
                "so it can fetch usage. Click OK to continue.",
            ].joined(separator: " "))
        case .minimaxCookie:
            return (title, [
                "CodexBar will ask macOS Keychain for your MiniMax cookie header",
                "so it can fetch usage. Click OK to continue.",
            ].joined(separator: " "))
        case .minimaxToken:
            return (title, [
                "CodexBar will ask macOS Keychain for your MiniMax API token",
                "so it can fetch usage. Click OK to continue.",
            ].joined(separator: " "))
        case .augmentCookie:
            return (title, [
                "CodexBar will ask macOS Keychain for your Augment cookie header",
                "so it can fetch usage. Click OK to continue.",
            ].joined(separator: " "))
        case .ampCookie:
            return (title, [
                "CodexBar will ask macOS Keychain for your Amp cookie header",
                "so it can fetch usage. Click OK to continue.",
            ].joined(separator: " "))
        }
    }

    private static func presentAlert(title: String, message: String) {
        self.promptLock.lock()
        defer { self.promptLock.unlock() }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.showAlert(title: title, message: message)
            }
            return
        }
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.showAlert(title: title, message: message)
            }
        }
    }

    @MainActor
    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}
