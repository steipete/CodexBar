import Foundation

extension TokenAccountSupportCatalog {
    static let supportByProvider: [UsageProvider: TokenAccountSupport] = [
        .claude: TokenAccountSupport(
            title: NSLocalizedString("Session tokens", comment: ""),
            subtitle: NSLocalizedString("Store Claude sessionKey cookies or OAuth access tokens.", comment: ""),
            placeholder: NSLocalizedString("Paste sessionKey or OAuth token...", comment: ""),
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: "sessionKey"),
        .zai: TokenAccountSupport(
            title: NSLocalizedString("API tokens", comment: ""),
            subtitle: NSLocalizedString("Stored in the CodexBar config file.", comment: ""),
            placeholder: NSLocalizedString("Paste token...", comment: ""),
            injection: .environment(key: ZaiSettingsReader.apiTokenKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        .cursor: TokenAccountSupport(
            title: NSLocalizedString("Session tokens", comment: ""),
            subtitle: NSLocalizedString("Store multiple Cursor Cookie headers.", comment: ""),
            placeholder: NSLocalizedString("Cookie: ...", comment: ""),
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .opencode: TokenAccountSupport(
            title: NSLocalizedString("Session tokens", comment: ""),
            subtitle: NSLocalizedString("Store multiple OpenCode Cookie headers.", comment: ""),
            placeholder: NSLocalizedString("Cookie: ...", comment: ""),
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .factory: TokenAccountSupport(
            title: NSLocalizedString("Session tokens", comment: ""),
            subtitle: NSLocalizedString("Store multiple Factory Cookie headers.", comment: ""),
            placeholder: NSLocalizedString("Cookie: ...", comment: ""),
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .minimax: TokenAccountSupport(
            title: NSLocalizedString("Session tokens", comment: ""),
            subtitle: NSLocalizedString("Store multiple MiniMax Cookie headers.", comment: ""),
            placeholder: NSLocalizedString("Cookie: ...", comment: ""),
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .augment: TokenAccountSupport(
            title: NSLocalizedString("Session tokens", comment: ""),
            subtitle: NSLocalizedString("Store multiple Augment Cookie headers.", comment: ""),
            placeholder: NSLocalizedString("Cookie: ...", comment: ""),
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .ollama: TokenAccountSupport(
            title: NSLocalizedString("Session tokens", comment: ""),
            subtitle: NSLocalizedString("Store multiple Ollama Cookie headers.", comment: ""),
            placeholder: NSLocalizedString("Cookie: ...", comment: ""),
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
    ]
}
