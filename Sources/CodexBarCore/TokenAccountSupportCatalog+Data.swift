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
        .codex: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store Codex/OpenAI Cookie headers, DevTools request dumps, or auth.json paths.",
            placeholder: "Cookie, auth.json path, or request dump…",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        .zai: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Stored in the CodexBar config file.",
            placeholder: "Paste token…",
            injection: .environment(key: ZaiSettingsReader.apiTokenKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        .copilot: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple Copilot API tokens.",
            placeholder: "Paste token…",
            injection: .environment(key: "COPILOT_API_TOKEN"),
            requiresManualCookieSource: false,
            cookieName: nil),
        .kimik2: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple Kimi K2 API tokens.",
            placeholder: "Paste token…",
            injection: .environment(key: KimiK2SettingsReader.apiKeyEnvironmentKeys[0]),
            requiresManualCookieSource: false,
            cookieName: nil),
        .synthetic: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple Synthetic API keys.",
            placeholder: "Paste key…",
            injection: .environment(key: SyntheticSettingsReader.apiKeyKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        .warp: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple Warp API tokens.",
            placeholder: "Paste token…",
            injection: .environment(key: WarpSettingsReader.apiKeyEnvironmentKeys[0]),
            requiresManualCookieSource: false,
            cookieName: nil),
        .openrouter: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple OpenRouter API keys.",
            placeholder: "Paste key…",
            injection: .environment(key: OpenRouterSettingsReader.envKey),
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
    ]
}
