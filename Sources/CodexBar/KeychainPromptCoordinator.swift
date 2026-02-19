import AppKit
import CodexBarCore
import SweetCookieKit

enum KeychainPromptCoordinator {
    private static let promptLock = NSLock()
    private static let log = CodexBarLog.logger(LogCategories.keychainPrompt)

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
        self.log.info("Keychain prompt requested", metadata: ["kind": "\(context.kind)"])
        self.presentAlert(title: title, message: message)
    }

    private static func presentBrowserCookiePrompt(_ context: BrowserCookieKeychainPromptContext) {
        let title = L10n.tr("Keychain Access Required")
        let message = L10n.format(
            "CodexBar will ask macOS Keychain for \"%@\" so it can decrypt browser cookies and authenticate your account. Click OK to continue.",
            context.label)
        self.log.info("Browser cookie keychain prompt requested", metadata: ["label": context.label])
        self.presentAlert(title: title, message: message)
    }

    private static func keychainCopy(for context: KeychainPromptContext) -> (title: String, message: String) {
        let title = L10n.tr("Keychain Access Required")
        switch context.kind {
        case .claudeOAuth:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for the Claude Code OAuth token so it can fetch your Claude usage. Click OK to continue."))
        case .codexCookie:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your OpenAI cookie header so it can fetch Codex dashboard extras. Click OK to continue."))
        case .claudeCookie:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your Claude cookie header so it can fetch Claude web usage. Click OK to continue."))
        case .cursorCookie:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your Cursor cookie header so it can fetch usage. Click OK to continue."))
        case .opencodeCookie:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your OpenCode cookie header so it can fetch usage. Click OK to continue."))
        case .factoryCookie:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your Factory cookie header so it can fetch usage. Click OK to continue."))
        case .zaiToken:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your z.ai API token so it can fetch usage. Click OK to continue."))
        case .syntheticToken:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your Synthetic API key so it can fetch usage. Click OK to continue."))
        case .copilotToken:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your GitHub Copilot token so it can fetch usage. Click OK to continue."))
        case .kimiToken:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your Kimi auth token so it can fetch usage. Click OK to continue."))
        case .kimiK2Token:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your Kimi K2 API key so it can fetch usage. Click OK to continue."))
        case .minimaxCookie:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your MiniMax cookie header so it can fetch usage. Click OK to continue."))
        case .minimaxToken:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your MiniMax API token so it can fetch usage. Click OK to continue."))
        case .augmentCookie:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your Augment cookie header so it can fetch usage. Click OK to continue."))
        case .ampCookie:
            return (title, L10n.tr(
                "CodexBar will ask macOS Keychain for your Amp cookie header so it can fetch usage. Click OK to continue."))
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
        alert.addButton(withTitle: L10n.tr("OK"))
        _ = alert.runModal()
    }
}
