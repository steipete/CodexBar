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
        let title = L("Keychain Access Required")
        let messageTemplate = L(
            "CodexBar will ask macOS Keychain for “%@” so it can decrypt browser cookies " +
                "and authenticate your account. Click OK to continue.")
        let message = String(
            format: messageTemplate,
            context.label)
        self.log.info("Browser cookie keychain prompt requested", metadata: ["label": context.label])
        self.presentAlert(title: title, message: message)
    }

    private static func keychainCopy(for context: KeychainPromptContext) -> (title: String, message: String) {
        let title = L("Keychain Access Required")
        switch context.kind {
        case .claudeOAuth:
            return (title, self.keychainFetchMessage(item: "the Claude Code OAuth token", purpose: "your Claude usage"))
        case .codexCookie:
            return (
                title,
                self.keychainFetchMessage(item: "your OpenAI cookie header", purpose: "Codex dashboard extras"))
        case .claudeCookie:
            return (title, self.keychainFetchMessage(item: "your Claude cookie header", purpose: "Claude web usage"))
        case .cursorCookie:
            return (title, self.keychainFetchMessage(item: "your Cursor cookie header"))
        case .opencodeCookie:
            return (title, self.keychainFetchMessage(item: "your OpenCode cookie header"))
        case .factoryCookie:
            return (title, self.keychainFetchMessage(item: "your Factory cookie header"))
        case .zaiToken:
            return (title, self.keychainFetchMessage(item: "your z.ai API token"))
        case .syntheticToken:
            return (title, self.keychainFetchMessage(item: "your Synthetic API key"))
        case .copilotToken:
            return (title, self.keychainFetchMessage(item: "your GitHub Copilot token"))
        case .kimiToken:
            return (title, self.keychainFetchMessage(item: "your Kimi auth token"))
        case .kimiK2Token:
            return (title, self.keychainFetchMessage(item: "your Kimi K2 API key"))
        case .minimaxCookie:
            return (title, self.keychainFetchMessage(item: "your MiniMax cookie header"))
        case .minimaxToken:
            return (title, self.keychainFetchMessage(item: "your MiniMax API token"))
        case .augmentCookie:
            return (title, self.keychainFetchMessage(item: "your Augment cookie header"))
        case .ampCookie:
            return (title, self.keychainFetchMessage(item: "your Amp cookie header"))
        }
    }

    private static func keychainFetchMessage(item: String, purpose: String = "usage") -> String {
        String(
            format: L("CodexBar will ask macOS Keychain for %@ so it can fetch %@. Click OK to continue."),
            L(item),
            L(purpose))
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
        alert.addButton(withTitle: L("OK"))
        _ = alert.runModal()
    }
}
