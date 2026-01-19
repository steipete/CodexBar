import CodexBarCore
import Foundation

extension SettingsStore {
    func providerConfig(for provider: UsageProvider) -> ProviderConfig? {
        self.config.providerConfig(for: provider)
    }

    var codexUsageDataSource: CodexUsageDataSource {
        get {
            let source = self.config.providerConfig(for: .codex)?.source
            return Self.codexUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .oauth: .oauth
            case .cli: .cli
            }
            self.updateProviderConfig(provider: .codex) { entry in
                entry.source = source
            }
        }
    }

    var claudeUsageDataSource: ClaudeUsageDataSource {
        get {
            let source = self.config.providerConfig(for: .claude)?.source
            return Self.claudeUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .oauth: .oauth
            case .web: .web
            case .cli: .cli
            }
            self.updateProviderConfig(provider: .claude) { entry in
                entry.source = source
            }
            if newValue != .cli {
                self.claudeWebExtrasEnabled = false
            }
        }
    }

    var opencodeWorkspaceID: String {
        get { self.config.providerConfig(for: .opencode)?.workspaceID ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed.isEmpty ? nil : trimmed
            self.updateProviderConfig(provider: .opencode) { entry in
                entry.workspaceID = value
            }
        }
    }

    var minimaxAPIRegion: MiniMaxAPIRegion {
        get {
            let raw = self.config.providerConfig(for: .minimax)?.region
            return MiniMaxAPIRegion(rawValue: raw ?? "") ?? .global
        }
        set {
            self.updateProviderConfig(provider: .minimax) { entry in
                entry.region = newValue.rawValue
            }
        }
    }

    var zaiAPIRegion: ZaiAPIRegion {
        get {
            let raw = self.config.providerConfig(for: .zai)?.region
            return ZaiAPIRegion(rawValue: raw ?? "") ?? .global
        }
        set {
            self.updateProviderConfig(provider: .zai) { entry in
                entry.region = newValue.rawValue
            }
        }
    }

    var zaiAPIToken: String {
        get { self.config.providerConfig(for: .zai)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .zai) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
        }
    }

    var syntheticAPIToken: String {
        get { self.config.providerConfig(for: .synthetic)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .synthetic) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
        }
    }

    var codexCookieHeader: String {
        get { self.config.providerConfig(for: .codex)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
        }
    }

    var claudeCookieHeader: String {
        get { self.config.providerConfig(for: .claude)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .claude) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
        }
    }

    var cursorCookieHeader: String {
        get { self.config.providerConfig(for: .cursor)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .cursor) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
        }
    }

    var opencodeCookieHeader: String {
        get { self.config.providerConfig(for: .opencode)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .opencode) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
        }
    }

    var factoryCookieHeader: String {
        get { self.config.providerConfig(for: .factory)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .factory) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
        }
    }

    var minimaxCookieHeader: String {
        get { self.config.providerConfig(for: .minimax)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .minimax) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
        }
    }

    var minimaxAPIToken: String {
        get { self.config.providerConfig(for: .minimax)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .minimax) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
        }
    }

    var kimiManualCookieHeader: String {
        get { self.config.providerConfig(for: .kimi)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .kimi) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
        }
    }

    var kimiK2APIToken: String {
        get { self.config.providerConfig(for: .kimik2)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .kimik2) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
        }
    }

    var augmentCookieHeader: String {
        get { self.config.providerConfig(for: .augment)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .augment) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
        }
    }

    var ampCookieHeader: String {
        get { self.config.providerConfig(for: .amp)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .amp) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
        }
    }

    var copilotAPIToken: String {
        get { self.config.providerConfig(for: .copilot)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .copilot) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
        }
    }

    var tokenAccountsByProvider: [UsageProvider: ProviderTokenAccountData] {
        get {
            Dictionary(uniqueKeysWithValues: self.config.providers.compactMap { entry in
                guard let accounts = entry.tokenAccounts else { return nil }
                return (entry.id, accounts)
            })
        }
        set {
            self.updateProviderTokenAccounts(newValue)
        }
    }

    var codexCookieSource: ProviderCookieSource {
        get {
            let fallback: ProviderCookieSource = self.openAIWebAccessEnabled ? .auto : .off
            return self.resolvedCookieSource(provider: .codex, fallback: fallback)
        }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.cookieSource = newValue
            }
            self.openAIWebAccessEnabled = newValue.isEnabled
        }
    }

    var claudeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .claude, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .claude) { entry in
                entry.cookieSource = newValue
            }
        }
    }

    var cursorCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .cursor, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .cursor) { entry in
                entry.cookieSource = newValue
            }
        }
    }

    var opencodeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .opencode, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .opencode) { entry in
                entry.cookieSource = newValue
            }
        }
    }

    var factoryCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .factory, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .factory) { entry in
                entry.cookieSource = newValue
            }
        }
    }

    var minimaxCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .minimax, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .minimax) { entry in
                entry.cookieSource = newValue
            }
        }
    }

    var kimiCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .kimi, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .kimi) { entry in
                entry.cookieSource = newValue
            }
        }
    }

    var augmentCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .augment, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .augment) { entry in
                entry.cookieSource = newValue
            }
        }
    }

    var ampCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .amp, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .amp) { entry in
                entry.cookieSource = newValue
            }
        }
    }

    func ensureZaiAPITokenLoaded() {}

    func ensureSyntheticAPITokenLoaded() {}

    func ensureCodexCookieLoaded() {}

    func ensureClaudeCookieLoaded() {}

    func ensureCursorCookieLoaded() {}

    func ensureOpenCodeCookieLoaded() {}

    func ensureFactoryCookieLoaded() {}

    func ensureMiniMaxCookieLoaded() {}

    func ensureMiniMaxAPITokenLoaded() {}

    func ensureKimiAuthTokenLoaded() {}

    func ensureKimiK2APITokenLoaded() {}

    func ensureAugmentCookieLoaded() {}

    func ensureAmpCookieLoaded() {}

    func ensureCopilotAPITokenLoaded() {}

    func minimaxAuthMode(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> MiniMaxAuthMode
    {
        let apiToken = MiniMaxAPISettingsReader.apiToken(environment: environment) ?? self.minimaxAPIToken
        let cookieHeader = MiniMaxSettingsReader.cookieHeader(environment: environment) ?? self.minimaxCookieHeader
        return MiniMaxAuthMode.resolve(apiToken: apiToken, cookieHeader: cookieHeader)
    }
}

extension SettingsStore {
    private static func codexUsageDataSource(from source: ProviderSourceMode?) -> CodexUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .web, .api:
            return .auto
        case .cli:
            return .cli
        case .oauth:
            return .oauth
        }
    }

    private static func claudeUsageDataSource(from source: ProviderSourceMode?) -> ClaudeUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .api:
            return .auto
        case .web:
            return .web
        case .cli:
            return .cli
        case .oauth:
            return .oauth
        }
    }

    private func resolvedCookieSource(
        provider: UsageProvider,
        fallback: ProviderCookieSource) -> ProviderCookieSource
    {
        let source = self.config.providerConfig(for: provider)?.cookieSource ?? fallback
        guard self.debugDisableKeychainAccess == false else { return source == .off ? .off : .manual }
        return source
    }
}
