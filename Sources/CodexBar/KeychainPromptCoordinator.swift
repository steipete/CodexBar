import AppKit
import CodexBarCore
import SweetCookieKit

private enum KeychainPromptMessage {
    static let browserCookie =
        "CodexBar will ask macOS Keychain for “%@” so it can decrypt browser cookies " +
        "and authenticate your account. Click OK to continue."

    static let claudeOAuth =
        "CodexBar will ask macOS Keychain for the Claude Code OAuth token " +
        "so it can fetch your Claude usage. Click OK to continue."
    static let codexCookie =
        "CodexBar will ask macOS Keychain for your OpenAI cookie header " +
        "so it can fetch Codex dashboard extras. Click OK to continue."
    static let claudeCookie =
        "CodexBar will ask macOS Keychain for your Claude cookie header " +
        "so it can fetch Claude web usage. Click OK to continue."
    static let cursorCookie =
        "CodexBar will ask macOS Keychain for your Cursor cookie header " +
        "so it can fetch usage. Click OK to continue."
    static let openCodeCookie =
        "CodexBar will ask macOS Keychain for your OpenCode cookie header " +
        "so it can fetch usage. Click OK to continue."
    static let factoryCookie =
        "CodexBar will ask macOS Keychain for your Factory cookie header " +
        "so it can fetch usage. Click OK to continue."
    static let zaiToken =
        "CodexBar will ask macOS Keychain for your z.ai API token " +
        "so it can fetch usage. Click OK to continue."
    static let syntheticToken =
        "CodexBar will ask macOS Keychain for your Synthetic API key " +
        "so it can fetch usage. Click OK to continue."
    static let copilotToken =
        "CodexBar will ask macOS Keychain for your GitHub Copilot token " +
        "so it can fetch usage. Click OK to continue."
    static let kimiToken =
        "CodexBar will ask macOS Keychain for your Kimi auth token " +
        "so it can fetch usage. Click OK to continue."
    static let minimaxCookie =
        "CodexBar will ask macOS Keychain for your MiniMax cookie header " +
        "so it can fetch usage. Click OK to continue."
    static let minimaxToken =
        "CodexBar will ask macOS Keychain for your MiniMax API token " +
        "so it can fetch usage. Click OK to continue."
    static let augmentCookie =
        "CodexBar will ask macOS Keychain for your Augment cookie header " +
        "so it can fetch usage. Click OK to continue."
    static let ampCookie =
        "CodexBar will ask macOS Keychain for your Amp cookie header " +
        "so it can fetch usage. Click OK to continue."
}

struct KeychainPromptAlertModel: Equatable {
    let title: String
    let message: String
    let primaryButtonTitle: String
    let learnMoreButtonTitle: String
    let documentationURL: String
}

@MainActor
private final class KeychainPromptLearnMoreTarget: NSObject {
    private let documentationURL: String

    init(documentationURL: String) {
        self.documentationURL = documentationURL
    }

    @objc func openDocumentation() {
        guard let url = URL(string: self.documentationURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum KeychainPromptCoordinator {
    private static let promptLock = NSLock()
    private static let log = CodexBarLog.logger(LogCategories.keychainPrompt)
    private static let documentationURL =
        "https://github.com/steipete/CodexBar/blob/main/docs/keychain-prompts.md"

    static func install() {
        KeychainPromptHandler.handler = { context in
            self.presentKeychainPrompt(context)
        }
        BrowserCookieKeychainPromptHandler.handler = { context in
            self.presentBrowserCookiePrompt(context)
        }
        self.disableKeychainForUnbundledExecutableIfNeeded()
    }

    private static let unbundledExecutableCheckLock = NSLock()
    private nonisolated(unsafe) static var didCheckUnbundledExecutable = false

    static func disableKeychainForUnbundledExecutableIfNeeded() {
        self.unbundledExecutableCheckLock.lock()
        guard !self.didCheckUnbundledExecutable else {
            self.unbundledExecutableCheckLock.unlock()
            return
        }
        self.didCheckUnbundledExecutable = true
        self.unbundledExecutableCheckLock.unlock()

        let executablePath = Bundle.main.executableURL?.path ?? ""
        guard Self.isUnbundledCodexBarExecutable(executablePath) else { return }
        KeychainAccessGate.forceDisabledForProcess(reason: "unbundled-executable")
        Self.log.warning(
            "Unbundled CodexBar executable detected; disabling keychain access to avoid repeated prompts",
            metadata: ["doc": "docs/DEVELOPMENT_SETUP.md"])
    }

    static func isUnbundledCodexBarExecutable(_ executablePath: String) -> Bool {
        guard executablePath.hasPrefix("/") else { return false }
        let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        return executableURL.lastPathComponent == "CodexBar"
            && !executableURL.pathComponents.contains(where: { $0.hasSuffix(".app") })
    }

    private static func presentKeychainPrompt(_ context: KeychainPromptContext) {
        let model = self.alertModel(for: context)
        self.log.info("Keychain prompt requested", metadata: ["kind": "\(context.kind)"])
        self.presentAlert(model)
    }

    private static func presentBrowserCookiePrompt(_ context: BrowserCookieKeychainPromptContext) {
        let model = self.browserCookieAlertModel(label: context.label)
        self.log.info("Browser cookie keychain prompt requested", metadata: ["label": context.label])
        self.presentAlert(model)
    }

    static func alertModel(for context: KeychainPromptContext) -> KeychainPromptAlertModel {
        let purpose = switch context.kind {
        case .claudeOAuth:
            L(KeychainPromptMessage.claudeOAuth)
        case .codexCookie:
            L(KeychainPromptMessage.codexCookie)
        case .claudeCookie:
            L(KeychainPromptMessage.claudeCookie)
        case .cursorCookie:
            L(KeychainPromptMessage.cursorCookie)
        case .opencodeCookie:
            L(KeychainPromptMessage.openCodeCookie)
        case .factoryCookie:
            L(KeychainPromptMessage.factoryCookie)
        case .zaiToken:
            L(KeychainPromptMessage.zaiToken)
        case .syntheticToken:
            L(KeychainPromptMessage.syntheticToken)
        case .copilotToken:
            L(KeychainPromptMessage.copilotToken)
        case .kimiToken:
            L(KeychainPromptMessage.kimiToken)
        case .minimaxCookie:
            L(KeychainPromptMessage.minimaxCookie)
        case .minimaxToken:
            L(KeychainPromptMessage.minimaxToken)
        case .augmentCookie:
            L(KeychainPromptMessage.augmentCookie)
        case .ampCookie:
            L(KeychainPromptMessage.ampCookie)
        }
        return self.alertModel(purpose: purpose)
    }

    static func browserCookieAlertModel(label: String) -> KeychainPromptAlertModel {
        self.alertModel(purpose: L(KeychainPromptMessage.browserCookie, label))
    }

    private static func alertModel(purpose: String) -> KeychainPromptAlertModel {
        KeychainPromptAlertModel(
            title: L("Keychain Access Required"),
            message: "\(purpose)\n\n\(L("keychain_prompt_privacy_note"))",
            primaryButtonTitle: L("OK"),
            learnMoreButtonTitle: L("keychain_prompt_learn_more"),
            documentationURL: self.documentationURL)
    }

    private static func presentAlert(_ model: KeychainPromptAlertModel) {
        self.promptLock.lock()
        defer { self.promptLock.unlock() }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.showAlert(model)
            }
            return
        }
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.showAlert(model)
            }
        }
    }

    @MainActor
    private static func showAlert(_ model: KeychainPromptAlertModel) {
        let alert = NSAlert()
        alert.messageText = model.title
        alert.informativeText = model.message
        alert.addButton(withTitle: model.primaryButtonTitle)

        let learnMoreTarget = KeychainPromptLearnMoreTarget(documentationURL: model.documentationURL)
        let learnMoreButton = NSButton(
            title: model.learnMoreButtonTitle,
            target: learnMoreTarget,
            action: #selector(KeychainPromptLearnMoreTarget.openDocumentation))
        learnMoreButton.isBordered = false
        learnMoreButton.contentTintColor = .linkColor
        learnMoreButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        learnMoreButton.sizeToFit()
        alert.accessoryView = learnMoreButton

        withExtendedLifetime(learnMoreTarget) {
            _ = alert.runModal()
        }
    }
}
