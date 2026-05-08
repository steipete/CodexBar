import Foundation

extension TokenAccountSupportCatalog {
    static let supportByProvider: [UsageProvider: TokenAccountSupport] = [
        .claude: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store Claude sessionKey cookies or OAuth access tokens.",
            placeholder: "Paste sessionKey or OAuth token…",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: "sessionKey"),
        .deepseek: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple DeepSeek API keys.",
            placeholder: "Paste API key…",
            injection: .environment(key: DeepSeekSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        .zai: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Stored in the CodexBar config file.",
            placeholder: "Paste token…",
            injection: .environment(key: ZaiSettingsReader.apiTokenKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        .cursor: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple Cursor Cookie headers.",
            placeholder: "Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .opencode: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple OpenCode Cookie headers.",
            placeholder: "Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .opencodego: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple OpenCode Go Cookie headers.",
            placeholder: "Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .factory: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple Factory Cookie headers.",
            placeholder: "Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .minimax: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple MiniMax Cookie headers.",
            placeholder: "Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .augment: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple Augment Cookie headers.",
            placeholder: "Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .ollama: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple Ollama Cookie headers.",
            placeholder: "Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .abacus: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple Abacus AI Cookie headers.",
            placeholder: "Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .mistral: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple Mistral Cookie headers.",
            placeholder: "Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .copilot: TokenAccountSupport(
            title: "GitHub accounts",
            subtitle: "Sign in with multiple GitHub accounts via OAuth.",
            placeholder: "Paste GitHub token…",
            injection: .environment(key: "COPILOT_API_TOKEN"),
            requiresManualCookieSource: false,
            cookieName: nil),
        .venice: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple Venice API keys.",
            placeholder: "Paste API key…",
            injection: .environment(key: VeniceSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
    ]
}
