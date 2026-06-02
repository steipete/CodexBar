import AppKit
import CodexBarCore
import Security
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
    static let kimiK2Token =
        "CodexBar will ask macOS Keychain for your Kimi K2 API key " +
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
        self.logAdHocDevBuildHintIfNeeded()
    }

    // MARK: - Dev-build self-diagnosis

    // One-shot guard. Safe to mutate from any context because
    // `install()` is the only writer (called once from `CodexbarApp.init` on
    // the main thread at app launch), and the read-modify-write is gated by
    // `adHocDevBuildHintLock`.
    private static let adHocDevBuildHintLock = NSLock()
    private nonisolated(unsafe) static var hasLoggedAdHocDevBuildHint = false

    /// Emit a one-shot log hint when CodexBar detects it is running from a
    /// SwiftPM dev build (`.build/<config>/debug/<Bundle>`) or with an
    /// ad-hoc signing identity. This is the common case that causes macOS
    /// to repeatedly prompt for "CodexBar wants to use your confidential
    /// information stored in 'CodexBarCache' in your keychain." — see
    /// `docs/LOCAL_DEV_BUILD.md`.
    ///
    /// Properly-signed release builds (Developer ID, installed in
    /// `/Applications`) do not match either condition and will not see the hint.
    static func logAdHocDevBuildHintIfNeeded() {
        self.adHocDevBuildHintLock.lock()
        if self.hasLoggedAdHocDevBuildHint {
            self.adHocDevBuildHintLock.unlock()
            return
        }
        self.hasLoggedAdHocDevBuildHint = true
        self.adHocDevBuildHintLock.unlock()

        // For SwiftPM executables, `Bundle.main.bundleURL` is the *directory*
        // containing the binary, not the binary itself. `SecStaticCodeCreateWithPath`
        // on a directory URL does not surface the inner executable's code-signing
        // identity the way `codesign -dvvv` does, so the directory URL would
        // produce a wrong (false) result here. Pass the executable URL — that
        // path is what `codesign -dvvv` reads, and what a properly-signed
        // `.app` bundle's `Contents/MacOS/<binary>` is.
        let codeURL = Bundle.main.executableURL ?? Bundle.main.bundleURL
        let isAdHoc = Self.isAdHocSigned(bundleURL: codeURL)
        guard let message = Self.adHocDevBuildHint(
            bundlePath: Bundle.main.bundleURL.path,
            executablePath: Bundle.main.executableURL?.path ?? "<unknown>",
            isAdHocSigned: isAdHoc) else { return }
        KeychainAccessGate.forceDisabledForProcess(reason: "ad-hoc-dev-build")
        Self.log.warning(
            "Ad-hoc dev build detected — disabling keychain access to avoid CodexBarCache prompts",
            metadata: [
                "bundlePath": Bundle.main.bundleURL.path,
                "adHocSigned": isAdHoc ? "true" : "false",
                "doc": "docs/LOCAL_DEV_BUILD.md",
            ])
        Self.log.info(message)
    }

    /// Pure: returns the warning message string when the given bundle path
    /// + signing state indicates an ad-hoc dev build, otherwise `nil`.
    /// Exposed for unit testing.
    static func adHocDevBuildHint(
        bundlePath: String,
        executablePath: String,
        isAdHocSigned: Bool) -> String?
    {
        let isSwiftPMDevBuild = bundlePath.contains("/.build/") && bundlePath.contains("/debug/")
        guard isSwiftPMDevBuild || isAdHocSigned else { return nil }
        return "CodexBar is running from a SwiftPM dev build or an ad-hoc-signed bundle " +
            "(bundle=\(bundlePath), exec=\(executablePath), adHoc=\(isAdHocSigned)). " +
            "This commonly causes macOS to repeatedly prompt for 'CodexBar wants to use your " +
            "confidential information stored in CodexBarCache in your keychain.' " +
            "CodexBar has disabled keychain access for this process to avoid the prompt loop. " +
            "Use /Applications/CodexBar.app for normal use, or run via ./Scripts/compile_and_run.sh. " +
            "See docs/LOCAL_DEV_BUILD.md."
    }

    /// True if the bundle at `bundleURL` is ad-hoc signed (no cert chain).
    /// Stable self-signed dev certificates may not have an Apple Team ID, but
    /// they still provide a certificate-backed identity and should not be
    /// treated as ad-hoc here.
    private static func isAdHocSigned(bundleURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode else { return false }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) ==
            errSecSuccess,
            let info = infoCF as? [String: Any] else { return false }
        return (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.isEmpty ?? true
    }

    private static func presentKeychainPrompt(_ context: KeychainPromptContext) {
        let (title, message) = self.keychainCopy(for: context)
        self.log.info("Keychain prompt requested", metadata: ["kind": "\(context.kind)"])
        self.presentAlert(title: title, message: message)
    }

    private static func presentBrowserCookiePrompt(_ context: BrowserCookieKeychainPromptContext) {
        let title = L("Keychain Access Required")
        let message = L(
            KeychainPromptMessage.browserCookie,
            context.label)
        self.log.info("Browser cookie keychain prompt requested", metadata: ["label": context.label])
        self.presentAlert(title: title, message: message)
    }

    private static func keychainCopy(for context: KeychainPromptContext) -> (title: String, message: String) {
        let title = L("Keychain Access Required")
        switch context.kind {
        case .claudeOAuth:
            return (title, L(KeychainPromptMessage.claudeOAuth))
        case .codexCookie:
            return (title, L(KeychainPromptMessage.codexCookie))
        case .claudeCookie:
            return (title, L(KeychainPromptMessage.claudeCookie))
        case .cursorCookie:
            return (title, L(KeychainPromptMessage.cursorCookie))
        case .opencodeCookie:
            return (title, L(KeychainPromptMessage.openCodeCookie))
        case .factoryCookie:
            return (title, L(KeychainPromptMessage.factoryCookie))
        case .zaiToken:
            return (title, L(KeychainPromptMessage.zaiToken))
        case .syntheticToken:
            return (title, L(KeychainPromptMessage.syntheticToken))
        case .copilotToken:
            return (title, L(KeychainPromptMessage.copilotToken))
        case .kimiToken:
            return (title, L(KeychainPromptMessage.kimiToken))
        case .kimiK2Token:
            return (title, L(KeychainPromptMessage.kimiK2Token))
        case .minimaxCookie:
            return (title, L(KeychainPromptMessage.minimaxCookie))
        case .minimaxToken:
            return (title, L(KeychainPromptMessage.minimaxToken))
        case .augmentCookie:
            return (title, L(KeychainPromptMessage.augmentCookie))
        case .ampCookie:
            return (title, L(KeychainPromptMessage.ampCookie))
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
        alert.messageText = L(title)
        alert.informativeText = L(message)
        alert.addButton(withTitle: L("OK"))
        _ = alert.runModal()
    }
}
