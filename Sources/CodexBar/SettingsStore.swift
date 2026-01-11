import AppKit
import CodexBarCore
import Observation
import ServiceManagement

enum RefreshFrequency: String, CaseIterable, Identifiable {
    case manual
    case oneMinute
    case twoMinutes
    case fiveMinutes
    case fifteenMinutes

    var id: String { self.rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .manual: nil
        case .oneMinute: 60
        case .twoMinutes: 120
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        }
    }

    var label: String {
        switch self {
        case .manual: "Manual"
        case .oneMinute: "1 min"
        case .twoMinutes: "2 min"
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    /// Persisted provider display order.
    ///
    /// Stored as raw `UsageProvider` strings so new providers can be appended automatically without breaking.
    private var providerOrderRaw: [String] {
        didSet { self.userDefaults.set(self.providerOrderRaw, forKey: "providerOrder") }
    }

    var refreshFrequency: RefreshFrequency {
        didSet { self.userDefaults.set(self.refreshFrequency.rawValue, forKey: "refreshFrequency") }
    }

    var launchAtLogin: Bool {
        didSet {
            self.userDefaults.set(self.launchAtLogin, forKey: "launchAtLogin")
            LaunchAtLoginManager.setEnabled(self.launchAtLogin)
        }
    }

    /// Hidden toggle to reveal debug-only menu items (enable via defaults write com.steipete.CodexBar debugMenuEnabled
    /// -bool YES).
    var debugMenuEnabled: Bool {
        didSet { self.userDefaults.set(self.debugMenuEnabled, forKey: "debugMenuEnabled") }
    }

    private var debugLoadingPatternRaw: String? {
        didSet {
            if let raw = self.debugLoadingPatternRaw {
                self.userDefaults.set(raw, forKey: "debugLoadingPattern")
            } else {
                self.userDefaults.removeObject(forKey: "debugLoadingPattern")
            }
        }
    }

    var statusChecksEnabled: Bool {
        didSet { self.userDefaults.set(self.statusChecksEnabled, forKey: "statusChecksEnabled") }
    }

    var sessionQuotaNotificationsEnabled: Bool {
        didSet {
            self.userDefaults.set(self.sessionQuotaNotificationsEnabled, forKey: "sessionQuotaNotificationsEnabled")
        }
    }

    /// When enabled, progress bars show "percent used" instead of "percent left".
    var usageBarsShowUsed: Bool {
        didSet { self.userDefaults.set(self.usageBarsShowUsed, forKey: "usageBarsShowUsed") }
    }

    /// Optional: show reset times as absolute clock values instead of countdowns.
    var resetTimesShowAbsolute: Bool {
        didSet { self.userDefaults.set(self.resetTimesShowAbsolute, forKey: "resetTimesShowAbsolute") }
    }

    /// Optional: use provider branding icons with a percentage in the menu bar.
    var menuBarShowsBrandIconWithPercent: Bool {
        didSet {
            self.userDefaults.set(self.menuBarShowsBrandIconWithPercent, forKey: "menuBarShowsBrandIconWithPercent")
        }
    }

    /// Optional: show provider cost summary from local usage logs (Codex + Claude).
    var costUsageEnabled: Bool {
        didSet { self.userDefaults.set(self.costUsageEnabled, forKey: "tokenCostUsageEnabled") }
    }

    var randomBlinkEnabled: Bool {
        didSet { self.userDefaults.set(self.randomBlinkEnabled, forKey: "randomBlinkEnabled") }
    }

    /// Optional: augment Claude usage with claude.ai web API (via browser cookies),
    /// incl. "Extra usage" spend.
    var claudeWebExtrasEnabled: Bool {
        didSet { self.userDefaults.set(self.claudeWebExtrasEnabled, forKey: "claudeWebExtrasEnabled") }
    }

    /// Optional: show Codex credits + Claude extra usage sections in the menu UI.
    var showOptionalCreditsAndExtraUsage: Bool {
        didSet {
            self.userDefaults.set(self.showOptionalCreditsAndExtraUsage, forKey: "showOptionalCreditsAndExtraUsage")
        }
    }

    /// Optional: fetch OpenAI web dashboard extras for Codex (browser cookies).
    var openAIWebAccessEnabled: Bool {
        didSet { self.userDefaults.set(self.openAIWebAccessEnabled, forKey: "openAIWebAccessEnabled") }
    }

    private var codexUsageDataSourceRaw: String? {
        didSet {
            if let raw = self.codexUsageDataSourceRaw {
                self.userDefaults.set(raw, forKey: "codexUsageDataSource")
            } else {
                self.userDefaults.removeObject(forKey: "codexUsageDataSource")
            }
        }
    }

    private var claudeUsageDataSourceRaw: String? {
        didSet {
            if let raw = self.claudeUsageDataSourceRaw {
                self.userDefaults.set(raw, forKey: "claudeUsageDataSource")
            } else {
                self.userDefaults.removeObject(forKey: "claudeUsageDataSource")
            }
        }
    }

    private var codexCookieSourceRaw: String? {
        didSet {
            if let raw = self.codexCookieSourceRaw {
                self.userDefaults.set(raw, forKey: "codexCookieSource")
            } else {
                self.userDefaults.removeObject(forKey: "codexCookieSource")
            }
        }
    }

    private var claudeCookieSourceRaw: String? {
        didSet {
            if let raw = self.claudeCookieSourceRaw {
                self.userDefaults.set(raw, forKey: "claudeCookieSource")
            } else {
                self.userDefaults.removeObject(forKey: "claudeCookieSource")
            }
        }
    }

    private var cursorCookieSourceRaw: String? {
        didSet {
            if let raw = self.cursorCookieSourceRaw {
                self.userDefaults.set(raw, forKey: "cursorCookieSource")
            } else {
                self.userDefaults.removeObject(forKey: "cursorCookieSource")
            }
        }
    }

    private var factoryCookieSourceRaw: String? {
        didSet {
            if let raw = self.factoryCookieSourceRaw {
                self.userDefaults.set(raw, forKey: "factoryCookieSource")
            } else {
                self.userDefaults.removeObject(forKey: "factoryCookieSource")
            }
        }
    }

    private var minimaxCookieSourceRaw: String? {
        didSet {
            if let raw = self.minimaxCookieSourceRaw {
                self.userDefaults.set(raw, forKey: "minimaxCookieSource")
            } else {
                self.userDefaults.removeObject(forKey: "minimaxCookieSource")
            }
        }
    }

    private var augmentCookieSourceRaw: String? {
        didSet {
            if let raw = self.augmentCookieSourceRaw {
                self.userDefaults.set(raw, forKey: "augmentCookieSource")
            } else {
                self.userDefaults.removeObject(forKey: "augmentCookieSource")
            }
        }
    }

    /// JetBrains IDE base path for quota file lookup.
    var jetbrainsIDEBasePath: String {
        didSet { self.userDefaults.set(self.jetbrainsIDEBasePath, forKey: "jetbrainsIDEBasePath") }
    }

    /// Optional: collapse provider icons into a single menu bar item with an in-menu switcher.
    var mergeIcons: Bool {
        didSet { self.userDefaults.set(self.mergeIcons, forKey: "mergeIcons") }
    }

    /// Optional: show provider icons in the in-menu switcher.
    var switcherShowsIcons: Bool {
        didSet { self.userDefaults.set(self.switcherShowsIcons, forKey: "switcherShowsIcons") }
    }

    /// z.ai API token (stored in Keychain).
    var zaiAPIToken: String {
        didSet { self.schedulePersistZaiAPIToken() }
    }

    /// Codex OpenAI cookie header (stored in Keychain).
    var codexCookieHeader: String {
        didSet { self.schedulePersistCodexCookieHeader() }
    }

    /// Claude session cookie header (stored in Keychain).
    var claudeCookieHeader: String {
        didSet { self.schedulePersistClaudeCookieHeader() }
    }

    /// Cursor session cookie header (stored in Keychain).
    var cursorCookieHeader: String {
        didSet { self.schedulePersistCursorCookieHeader() }
    }

    /// Factory session cookie header (stored in Keychain).
    var factoryCookieHeader: String {
        didSet { self.schedulePersistFactoryCookieHeader() }
    }

    /// MiniMax cookie header (stored in Keychain).
    var minimaxCookieHeader: String {
        didSet { self.schedulePersistMiniMaxCookieHeader() }
    }

    /// Augment session cookie header (stored in Keychain).
    var augmentCookieHeader: String {
        didSet { self.schedulePersistAugmentCookieHeader() }
    }

    /// Copilot API token (stored in Keychain).
    var copilotAPIToken: String {
        didSet { self.schedulePersistCopilotAPIToken() }
    }

    private var selectedMenuProviderRaw: String? {
        didSet {
            if let raw = self.selectedMenuProviderRaw {
                self.userDefaults.set(raw, forKey: "selectedMenuProvider")
            } else {
                self.userDefaults.removeObject(forKey: "selectedMenuProvider")
            }
        }
    }

    /// Optional override for the loading animation pattern, exposed via the Debug tab.
    var debugLoadingPattern: LoadingPattern? {
        get { self.debugLoadingPatternRaw.flatMap(LoadingPattern.init(rawValue:)) }
        set {
            self.debugLoadingPatternRaw = newValue?.rawValue
        }
    }

    var selectedMenuProvider: UsageProvider? {
        get { self.selectedMenuProviderRaw.flatMap(UsageProvider.init(rawValue:)) }
        set {
            self.selectedMenuProviderRaw = newValue?.rawValue
        }
    }

    var resetTimeDisplayStyle: ResetTimeDisplayStyle {
        self.resetTimesShowAbsolute ? .absolute : .countdown
    }

    var codexUsageDataSource: CodexUsageDataSource {
        get { CodexUsageDataSource(rawValue: self.codexUsageDataSourceRaw ?? "") ?? .auto }
        set {
            self.codexUsageDataSourceRaw = newValue.rawValue
        }
    }

    var claudeUsageDataSource: ClaudeUsageDataSource {
        get { ClaudeUsageDataSource(rawValue: self.claudeUsageDataSourceRaw ?? "") ?? .auto }
        set {
            self.claudeUsageDataSourceRaw = newValue.rawValue
            if newValue != .cli {
                self.claudeWebExtrasEnabled = false
            }
        }
    }

    var codexCookieSource: ProviderCookieSource {
        get { ProviderCookieSource(rawValue: self.codexCookieSourceRaw ?? "") ?? .auto }
        set {
            self.codexCookieSourceRaw = newValue.rawValue
            self.openAIWebAccessEnabled = newValue.isEnabled
        }
    }

    var claudeCookieSource: ProviderCookieSource {
        get { ProviderCookieSource(rawValue: self.claudeCookieSourceRaw ?? "") ?? .auto }
        set { self.claudeCookieSourceRaw = newValue.rawValue }
    }

    var cursorCookieSource: ProviderCookieSource {
        get { ProviderCookieSource(rawValue: self.cursorCookieSourceRaw ?? "") ?? .auto }
        set { self.cursorCookieSourceRaw = newValue.rawValue }
    }

    var factoryCookieSource: ProviderCookieSource {
        get { ProviderCookieSource(rawValue: self.factoryCookieSourceRaw ?? "") ?? .auto }
        set { self.factoryCookieSourceRaw = newValue.rawValue }
    }

    var minimaxCookieSource: ProviderCookieSource {
        get { ProviderCookieSource(rawValue: self.minimaxCookieSourceRaw ?? "") ?? .auto }
        set { self.minimaxCookieSourceRaw = newValue.rawValue }
    }

    var augmentCookieSource: ProviderCookieSource {
        get { ProviderCookieSource(rawValue: self.augmentCookieSourceRaw ?? "") ?? .auto }
        set { self.augmentCookieSourceRaw = newValue.rawValue }
    }

    var menuObservationToken: Int {
        _ = self.providerOrderRaw
        _ = self.refreshFrequency
        _ = self.launchAtLogin
        _ = self.debugMenuEnabled
        _ = self.statusChecksEnabled
        _ = self.sessionQuotaNotificationsEnabled
        _ = self.usageBarsShowUsed
        _ = self.resetTimesShowAbsolute
        _ = self.menuBarShowsBrandIconWithPercent
        _ = self.costUsageEnabled
        _ = self.randomBlinkEnabled
        _ = self.claudeWebExtrasEnabled
        _ = self.showOptionalCreditsAndExtraUsage
        _ = self.openAIWebAccessEnabled
        _ = self.codexUsageDataSource
        _ = self.claudeUsageDataSource
        _ = self.codexCookieSource
        _ = self.claudeCookieSource
        _ = self.cursorCookieSource
        _ = self.factoryCookieSource
        _ = self.minimaxCookieSource
        _ = self.mergeIcons
        _ = self.switcherShowsIcons
        _ = self.zaiAPIToken
        _ = self.codexCookieHeader
        _ = self.claudeCookieHeader
        _ = self.cursorCookieHeader
        _ = self.factoryCookieHeader
        _ = self.minimaxCookieHeader
        _ = self.copilotAPIToken
        _ = self.debugLoadingPattern
        _ = self.selectedMenuProvider
        _ = self.providerToggleRevision
        return 0
    }

    private var providerDetectionCompleted: Bool {
        didSet { self.userDefaults.set(self.providerDetectionCompleted, forKey: "providerDetectionCompleted") }
    }

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let toggleStore: ProviderToggleStore
    @ObservationIgnored private let zaiTokenStore: any ZaiTokenStoring
    @ObservationIgnored private var zaiTokenPersistTask: Task<Void, Never>?
    @ObservationIgnored private var zaiTokenLoaded = false
    @ObservationIgnored private var zaiTokenLoading = false
    @ObservationIgnored private let codexCookieStore: any CookieHeaderStoring
    @ObservationIgnored private var codexCookiePersistTask: Task<Void, Never>?
    @ObservationIgnored private var codexCookieLoaded = false
    @ObservationIgnored private var codexCookieLoading = false
    @ObservationIgnored private let claudeCookieStore: any CookieHeaderStoring
    @ObservationIgnored private var claudeCookiePersistTask: Task<Void, Never>?
    @ObservationIgnored private var claudeCookieLoaded = false
    @ObservationIgnored private var claudeCookieLoading = false
    @ObservationIgnored private let cursorCookieStore: any CookieHeaderStoring
    @ObservationIgnored private var cursorCookiePersistTask: Task<Void, Never>?
    @ObservationIgnored private var cursorCookieLoaded = false
    @ObservationIgnored private var cursorCookieLoading = false
    @ObservationIgnored private let factoryCookieStore: any CookieHeaderStoring
    @ObservationIgnored private var factoryCookiePersistTask: Task<Void, Never>?
    @ObservationIgnored private var factoryCookieLoaded = false
    @ObservationIgnored private var factoryCookieLoading = false
    @ObservationIgnored private let minimaxCookieStore: any MiniMaxCookieStoring
    @ObservationIgnored private var minimaxCookiePersistTask: Task<Void, Never>?
    @ObservationIgnored private var minimaxCookieLoaded = false
    @ObservationIgnored private var minimaxCookieLoading = false
    @ObservationIgnored private let augmentCookieStore: any CookieHeaderStoring
    @ObservationIgnored private var augmentCookiePersistTask: Task<Void, Never>?
    @ObservationIgnored private var augmentCookieLoaded = false
    @ObservationIgnored private var augmentCookieLoading = false
    @ObservationIgnored private let copilotTokenStore: any CopilotTokenStoring
    @ObservationIgnored private var copilotTokenPersistTask: Task<Void, Never>?
    @ObservationIgnored private var copilotTokenLoaded = false
    @ObservationIgnored private var copilotTokenLoading = false
    // Cache enablement so tight UI loops (menu bar animations) don't hit UserDefaults each tick.
    @ObservationIgnored private var cachedProviderEnablement: [UsageProvider: Bool] = [:]
    @ObservationIgnored private var cachedProviderEnablementRevision: Int = -1
    @ObservationIgnored private var cachedEnabledProviders: [UsageProvider] = []
    @ObservationIgnored private var cachedEnabledProvidersRevision: Int = -1
    @ObservationIgnored private var cachedEnabledProvidersOrderRaw: [String] = []
    // Cache order to avoid re-building sets/arrays every animation tick.
    @ObservationIgnored private var cachedProviderOrder: [UsageProvider] = []
    @ObservationIgnored private var cachedProviderOrderRaw: [String] = []
    private var providerToggleRevision: Int = 0

    init(
        userDefaults: UserDefaults = .standard,
        zaiTokenStore: any ZaiTokenStoring = KeychainZaiTokenStore(),
        codexCookieStore: any CookieHeaderStoring = KeychainCookieHeaderStore(
            account: "codex-cookie",
            promptKind: .codexCookie),
        claudeCookieStore: any CookieHeaderStoring = KeychainCookieHeaderStore(
            account: "claude-cookie",
            promptKind: .claudeCookie),
        cursorCookieStore: any CookieHeaderStoring = KeychainCookieHeaderStore(
            account: "cursor-cookie",
            promptKind: .cursorCookie),
        factoryCookieStore: any CookieHeaderStoring = KeychainCookieHeaderStore(
            account: "factory-cookie",
            promptKind: .factoryCookie),
        minimaxCookieStore: any MiniMaxCookieStoring = KeychainMiniMaxCookieStore(),
        augmentCookieStore: any CookieHeaderStoring = KeychainCookieHeaderStore(
            account: "augment-cookie",
            promptKind: .augmentCookie),
        copilotTokenStore: any CopilotTokenStoring = KeychainCopilotTokenStore())
    {
        self.userDefaults = userDefaults
        self.zaiTokenStore = zaiTokenStore
        self.codexCookieStore = codexCookieStore
        self.claudeCookieStore = claudeCookieStore
        self.cursorCookieStore = cursorCookieStore
        self.factoryCookieStore = factoryCookieStore
        self.minimaxCookieStore = minimaxCookieStore
        self.augmentCookieStore = augmentCookieStore
        self.copilotTokenStore = copilotTokenStore
        self.providerOrderRaw = userDefaults.stringArray(forKey: "providerOrder") ?? []
        let raw = userDefaults.string(forKey: "refreshFrequency") ?? RefreshFrequency.fiveMinutes.rawValue
        self.refreshFrequency = RefreshFrequency(rawValue: raw) ?? .fiveMinutes
        self.launchAtLogin = userDefaults.object(forKey: "launchAtLogin") as? Bool ?? false
        self.debugMenuEnabled = userDefaults.object(forKey: "debugMenuEnabled") as? Bool ?? false
        self.debugLoadingPatternRaw = userDefaults.string(forKey: "debugLoadingPattern")
        self.statusChecksEnabled = userDefaults.object(forKey: "statusChecksEnabled") as? Bool ?? true
        let sessionQuotaNotificationsDefault = userDefaults.object(
            forKey: "sessionQuotaNotificationsEnabled") as? Bool
        self.sessionQuotaNotificationsEnabled = sessionQuotaNotificationsDefault ?? true
        if sessionQuotaNotificationsDefault == nil {
            self.userDefaults.set(true, forKey: "sessionQuotaNotificationsEnabled")
        }
        self.usageBarsShowUsed = userDefaults.object(forKey: "usageBarsShowUsed") as? Bool ?? false
        self.resetTimesShowAbsolute = userDefaults.object(forKey: "resetTimesShowAbsolute") as? Bool ?? false
        self.menuBarShowsBrandIconWithPercent = userDefaults.object(
            forKey: "menuBarShowsBrandIconWithPercent") as? Bool ?? false
        self.costUsageEnabled = userDefaults.object(forKey: "tokenCostUsageEnabled") as? Bool ?? false
        self.randomBlinkEnabled = userDefaults.object(forKey: "randomBlinkEnabled") as? Bool ?? false
        self.claudeWebExtrasEnabled = userDefaults.object(forKey: "claudeWebExtrasEnabled") as? Bool ?? false
        let creditsExtrasDefault = userDefaults.object(forKey: "showOptionalCreditsAndExtraUsage") as? Bool
        self.showOptionalCreditsAndExtraUsage = creditsExtrasDefault ?? true
        if creditsExtrasDefault == nil {
            self.userDefaults.set(true, forKey: "showOptionalCreditsAndExtraUsage")
        }
        let openAIWebAccessDefault = userDefaults.object(forKey: "openAIWebAccessEnabled") as? Bool
        let openAIWebAccessEnabled = openAIWebAccessDefault ?? true
        self.openAIWebAccessEnabled = openAIWebAccessEnabled
        if openAIWebAccessDefault == nil {
            self.userDefaults.set(true, forKey: "openAIWebAccessEnabled")
        }
        let codexSourceRaw = userDefaults.string(forKey: "codexUsageDataSource")
        self.codexUsageDataSourceRaw = codexSourceRaw ?? CodexUsageDataSource.auto.rawValue
        let claudeSourceRaw = userDefaults.string(forKey: "claudeUsageDataSource")
        self.claudeUsageDataSourceRaw = claudeSourceRaw ?? ClaudeUsageDataSource.auto.rawValue
        let codexCookieRaw = userDefaults.string(forKey: "codexCookieSource")
        if let codexCookieRaw {
            self.codexCookieSourceRaw = codexCookieRaw
        } else {
            let fallback = openAIWebAccessEnabled ? ProviderCookieSource.auto : .off
            self.codexCookieSourceRaw = fallback.rawValue
        }
        self.claudeCookieSourceRaw = userDefaults.string(forKey: "claudeCookieSource")
            ?? ProviderCookieSource.auto.rawValue
        self.cursorCookieSourceRaw = userDefaults.string(forKey: "cursorCookieSource")
            ?? ProviderCookieSource.auto.rawValue
        self.factoryCookieSourceRaw = userDefaults.string(forKey: "factoryCookieSource")
            ?? ProviderCookieSource.auto.rawValue
        self.minimaxCookieSourceRaw = userDefaults.string(forKey: "minimaxCookieSource")
            ?? ProviderCookieSource.auto.rawValue
        self.augmentCookieSourceRaw = userDefaults.string(forKey: "augmentCookieSource")
            ?? ProviderCookieSource.auto.rawValue
        self.jetbrainsIDEBasePath = userDefaults.string(forKey: "jetbrainsIDEBasePath") ?? ""
        self.mergeIcons = userDefaults.object(forKey: "mergeIcons") as? Bool ?? true
        self.switcherShowsIcons = userDefaults.object(forKey: "switcherShowsIcons") as? Bool ?? true
        self.zaiAPIToken = ""
        self.codexCookieHeader = ""
        self.claudeCookieHeader = ""
        self.cursorCookieHeader = ""
        self.factoryCookieHeader = ""
        self.minimaxCookieHeader = ""
        self.augmentCookieHeader = ""
        self.copilotAPIToken = ""
        self.selectedMenuProviderRaw = userDefaults.string(forKey: "selectedMenuProvider")
        self.providerDetectionCompleted = userDefaults.object(
            forKey: "providerDetectionCompleted") as? Bool ?? false
        self.toggleStore = ProviderToggleStore(userDefaults: userDefaults)
        self.toggleStore.purgeLegacyKeys()
        LaunchAtLoginManager.setEnabled(self.launchAtLogin)
        self.runInitialProviderDetectionIfNeeded()
        self.applyTokenCostDefaultIfNeeded()
        if self.claudeUsageDataSource != .cli {
            self.claudeWebExtrasEnabled = false
        }
        self.openAIWebAccessEnabled = self.codexCookieSource.isEnabled
    }

    func orderedProviders() -> [UsageProvider] {
        let raw = self.providerOrderRaw
        if raw == self.cachedProviderOrderRaw, !self.cachedProviderOrder.isEmpty {
            return self.cachedProviderOrder
        }
        let ordered = Self.effectiveProviderOrder(raw: raw)
        self.cachedProviderOrderRaw = raw
        self.cachedProviderOrder = ordered
        return ordered
    }

    func moveProvider(fromOffsets: IndexSet, toOffset: Int) {
        var order = self.orderedProviders()
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
        self.providerOrderRaw = order.map(\.rawValue)
    }

    func isProviderEnabled(provider: UsageProvider, metadata: ProviderMetadata) -> Bool {
        _ = self.providerToggleRevision
        return self.toggleStore.isEnabled(metadata: metadata)
    }

    func isProviderEnabledCached(
        provider: UsageProvider,
        metadataByProvider: [UsageProvider: ProviderMetadata]) -> Bool
    {
        self.refreshProviderEnablementCacheIfNeeded(metadataByProvider: metadataByProvider)
        return self.cachedProviderEnablement[provider] ?? false
    }

    func enabledProvidersOrdered(metadataByProvider: [UsageProvider: ProviderMetadata]) -> [UsageProvider] {
        self.refreshProviderEnablementCacheIfNeeded(metadataByProvider: metadataByProvider)
        let orderRaw = self.providerOrderRaw
        let revision = self.cachedProviderEnablementRevision
        if revision == self.cachedEnabledProvidersRevision,
           orderRaw == self.cachedEnabledProvidersOrderRaw,
           !self.cachedEnabledProviders.isEmpty
        {
            return self.cachedEnabledProviders
        }
        let enabled = self.orderedProviders().filter { self.cachedProviderEnablement[$0] ?? false }
        self.cachedEnabledProviders = enabled
        self.cachedEnabledProvidersRevision = revision
        self.cachedEnabledProvidersOrderRaw = orderRaw
        return enabled
    }

    func setProviderEnabled(provider: UsageProvider, metadata: ProviderMetadata, enabled: Bool) {
        self.providerToggleRevision &+= 1
        self.toggleStore.setEnabled(enabled, metadata: metadata)
    }

    func rerunProviderDetection() {
        self.runInitialProviderDetectionIfNeeded(force: true)
    }

    // MARK: - Private

    func isCostUsageEffectivelyEnabled(for provider: UsageProvider) -> Bool {
        self.costUsageEnabled
            && ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost
    }

    private static func effectiveProviderOrder(raw: [String]) -> [UsageProvider] {
        var seen: Set<UsageProvider> = []
        var ordered: [UsageProvider] = []

        for rawValue in raw {
            guard let provider = UsageProvider(rawValue: rawValue) else { continue }
            guard !seen.contains(provider) else { continue }
            seen.insert(provider)
            ordered.append(provider)
        }

        if ordered.isEmpty {
            ordered = UsageProvider.allCases
            seen = Set(ordered)
        }

        if !seen.contains(.factory), let zaiIndex = ordered.firstIndex(of: .zai) {
            ordered.insert(.factory, at: zaiIndex)
            seen.insert(.factory)
        }

        if !seen.contains(.minimax), let zaiIndex = ordered.firstIndex(of: .zai) {
            let insertIndex = ordered.index(after: zaiIndex)
            ordered.insert(.minimax, at: insertIndex)
            seen.insert(.minimax)
        }

        for provider in UsageProvider.allCases where !seen.contains(provider) {
            ordered.append(provider)
        }

        return ordered
    }

    private func refreshProviderEnablementCacheIfNeeded(
        metadataByProvider: [UsageProvider: ProviderMetadata])
    {
        let revision = self.providerToggleRevision
        guard revision != self.cachedProviderEnablementRevision else { return }
        var cache: [UsageProvider: Bool] = [:]
        for (provider, metadata) in metadataByProvider {
            cache[provider] = self.toggleStore.isEnabled(metadata: metadata)
        }
        self.cachedProviderEnablement = cache
        self.cachedProviderEnablementRevision = revision
    }

    private func runInitialProviderDetectionIfNeeded(force: Bool = false) {
        guard force || !self.providerDetectionCompleted else { return }
        guard let codexMeta = ProviderRegistry.shared.metadata[.codex],
              let claudeMeta = ProviderRegistry.shared.metadata[.claude],
              let geminiMeta = ProviderRegistry.shared.metadata[.gemini],
              let antigravityMeta = ProviderRegistry.shared.metadata[.antigravity] else { return }

        LoginShellPathCache.shared.captureOnce { [weak self] _ in
            Task { @MainActor in
                await self?.applyProviderDetection(
                    codexMeta: codexMeta,
                    claudeMeta: claudeMeta,
                    geminiMeta: geminiMeta,
                    antigravityMeta: antigravityMeta)
            }
        }
    }

    private func applyProviderDetection(
        codexMeta: ProviderMetadata,
        claudeMeta: ProviderMetadata,
        geminiMeta: ProviderMetadata,
        antigravityMeta: ProviderMetadata) async
    {
        guard !self.providerDetectionCompleted else { return }
        let codexInstalled = BinaryLocator.resolveCodexBinary() != nil
        let claudeInstalled = BinaryLocator.resolveClaudeBinary() != nil
        let geminiInstalled = BinaryLocator.resolveGeminiBinary() != nil
        let antigravityRunning = await AntigravityStatusProbe.isRunning()

        // If none installed, keep Codex enabled to match previous behavior.
        let noneInstalled = !codexInstalled && !claudeInstalled && !geminiInstalled && !antigravityRunning
        let enableCodex = codexInstalled || noneInstalled
        let enableClaude = claudeInstalled
        let enableGemini = geminiInstalled
        let enableAntigravity = antigravityRunning

        self.providerToggleRevision &+= 1
        self.toggleStore.setEnabled(enableCodex, metadata: codexMeta)
        self.toggleStore.setEnabled(enableClaude, metadata: claudeMeta)
        self.toggleStore.setEnabled(enableGemini, metadata: geminiMeta)
        self.toggleStore.setEnabled(enableAntigravity, metadata: antigravityMeta)
        self.providerDetectionCompleted = true
    }

    private func applyTokenCostDefaultIfNeeded() {
        // Settings are persisted in UserDefaults.standard.
        guard UserDefaults.standard.object(forKey: "tokenCostUsageEnabled") == nil else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let hasSources = await Task.detached(priority: .utility) {
                Self.hasAnyTokenCostUsageSources()
            }.value
            guard hasSources else { return }
            guard UserDefaults.standard.object(forKey: "tokenCostUsageEnabled") == nil else { return }
            self.costUsageEnabled = true
        }
    }

    nonisolated static func hasAnyTokenCostUsageSources(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> Bool
    {
        func hasAnyJsonl(in root: URL) -> Bool {
            guard fileManager.fileExists(atPath: root.path) else { return false }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return false }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                return true
            }
            return false
        }

        let codexRoot: URL = {
            let raw = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let raw, !raw.isEmpty {
                return URL(fileURLWithPath: raw).appendingPathComponent("sessions", isDirectory: true)
            }
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }()
        if hasAnyJsonl(in: codexRoot) { return true }

        let claudeRoots: [URL] = {
            if let env = env["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !env.isEmpty
            {
                return env.split(separator: ",").map { part in
                    let raw = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = URL(fileURLWithPath: raw)
                    if url.lastPathComponent == "projects" {
                        return url
                    }
                    return url.appendingPathComponent("projects", isDirectory: true)
                }
            }

            let home = fileManager.homeDirectoryForCurrentUser
            return [
                home.appendingPathComponent(".config/claude/projects", isDirectory: true),
                home.appendingPathComponent(".claude/projects", isDirectory: true),
            ]
        }()

        return claudeRoots.contains(where: hasAnyJsonl(in:))
    }
}

extension SettingsStore {
    private func schedulePersistZaiAPIToken() {
        if self.zaiTokenLoading { return }
        self.zaiTokenPersistTask?.cancel()
        let token = self.zaiAPIToken
        let tokenStore = self.zaiTokenStore
        self.zaiTokenPersistTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let error: (any Error)? = await Task.detached(priority: .utility) { () -> (any Error)? in
                do {
                    try tokenStore.storeToken(token)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error {
                // Keep value in memory; persist best-effort.
                CodexBarLog.logger("zai-token-store").error("Failed to persist z.ai token: \(error)")
            }
        }
    }

    private func schedulePersistCodexCookieHeader() {
        if self.codexCookieLoading { return }
        self.codexCookiePersistTask?.cancel()
        let header = self.codexCookieHeader
        let cookieStore = self.codexCookieStore
        self.codexCookiePersistTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let error: (any Error)? = await Task.detached(priority: .utility) { () -> (any Error)? in
                do {
                    try cookieStore.storeCookieHeader(header)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error {
                CodexBarLog.logger("codex-cookie-store").error("Failed to persist Codex cookie: \(error)")
            }
        }
    }

    private func schedulePersistClaudeCookieHeader() {
        if self.claudeCookieLoading { return }
        self.claudeCookiePersistTask?.cancel()
        let header = self.claudeCookieHeader
        let cookieStore = self.claudeCookieStore
        self.claudeCookiePersistTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let error: (any Error)? = await Task.detached(priority: .utility) { () -> (any Error)? in
                do {
                    try cookieStore.storeCookieHeader(header)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error {
                CodexBarLog.logger("claude-cookie-store").error("Failed to persist Claude cookie: \(error)")
            }
        }
    }

    private func schedulePersistCursorCookieHeader() {
        if self.cursorCookieLoading { return }
        self.cursorCookiePersistTask?.cancel()
        let header = self.cursorCookieHeader
        let cookieStore = self.cursorCookieStore
        self.cursorCookiePersistTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let error: (any Error)? = await Task.detached(priority: .utility) { () -> (any Error)? in
                do {
                    try cookieStore.storeCookieHeader(header)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error {
                CodexBarLog.logger("cursor-cookie-store").error("Failed to persist Cursor cookie: \(error)")
            }
        }
    }

    private func schedulePersistAugmentCookieHeader() {
        if self.augmentCookieLoading { return }
        self.augmentCookiePersistTask?.cancel()
        let header = self.augmentCookieHeader
        let cookieStore = self.augmentCookieStore
        self.augmentCookiePersistTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let error: (any Error)? = await Task.detached(priority: .utility) { () -> (any Error)? in
                do {
                    try cookieStore.storeCookieHeader(header)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error {
                CodexBarLog.logger("augment-cookie-store").error("Failed to persist Augment cookie: \(error)")
            }
        }
    }

    private func schedulePersistFactoryCookieHeader() {
        if self.factoryCookieLoading { return }
        self.factoryCookiePersistTask?.cancel()
        let header = self.factoryCookieHeader
        let cookieStore = self.factoryCookieStore
        self.factoryCookiePersistTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let error: (any Error)? = await Task.detached(priority: .utility) { () -> (any Error)? in
                do {
                    try cookieStore.storeCookieHeader(header)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error {
                CodexBarLog.logger("factory-cookie-store").error("Failed to persist Factory cookie: \(error)")
            }
        }
    }

    private func schedulePersistMiniMaxCookieHeader() {
        if self.minimaxCookieLoading { return }
        self.minimaxCookiePersistTask?.cancel()
        let header = self.minimaxCookieHeader
        let cookieStore = self.minimaxCookieStore
        self.minimaxCookiePersistTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let error: (any Error)? = await Task.detached(priority: .utility) { () -> (any Error)? in
                do {
                    try cookieStore.storeCookieHeader(header)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error {
                CodexBarLog.logger("minimax-cookie-store").error("Failed to persist MiniMax cookie: \(error)")
            }
        }
    }

    private func schedulePersistCopilotAPIToken() {
        if self.copilotTokenLoading { return }
        self.copilotTokenPersistTask?.cancel()
        let token = self.copilotAPIToken
        let tokenStore = self.copilotTokenStore
        self.copilotTokenPersistTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let error: (any Error)? = await Task.detached(priority: .utility) { () -> (any Error)? in
                do {
                    try tokenStore.storeToken(token)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error {
                CodexBarLog.logger("copilot-token-store").error("Failed to persist Copilot token: \(error)")
            }
        }
    }
}

extension SettingsStore {
    func ensureZaiAPITokenLoaded() {
        guard !self.zaiTokenLoaded else { return }
        self.zaiTokenLoading = true
        self.zaiAPIToken = (try? self.zaiTokenStore.loadToken()) ?? ""
        self.zaiTokenLoading = false
        self.zaiTokenLoaded = true
    }

    func ensureCodexCookieLoaded() {
        guard !self.codexCookieLoaded else { return }
        self.codexCookieLoading = true
        self.codexCookieHeader = (try? self.codexCookieStore.loadCookieHeader()) ?? ""
        self.codexCookieLoading = false
        self.codexCookieLoaded = true
    }

    func ensureClaudeCookieLoaded() {
        guard !self.claudeCookieLoaded else { return }
        self.claudeCookieLoading = true
        self.claudeCookieHeader = (try? self.claudeCookieStore.loadCookieHeader()) ?? ""
        self.claudeCookieLoading = false
        self.claudeCookieLoaded = true
    }

    func ensureCursorCookieLoaded() {
        guard !self.cursorCookieLoaded else { return }
        self.cursorCookieLoading = true
        self.cursorCookieHeader = (try? self.cursorCookieStore.loadCookieHeader()) ?? ""
        self.cursorCookieLoading = false
        self.cursorCookieLoaded = true
    }

    func ensureFactoryCookieLoaded() {
        guard !self.factoryCookieLoaded else { return }
        self.factoryCookieLoading = true
        self.factoryCookieHeader = (try? self.factoryCookieStore.loadCookieHeader()) ?? ""
        self.factoryCookieLoading = false
        self.factoryCookieLoaded = true
    }

    func ensureMiniMaxCookieLoaded() {
        guard !self.minimaxCookieLoaded else { return }
        self.minimaxCookieLoading = true
        self.minimaxCookieHeader = (try? self.minimaxCookieStore.loadCookieHeader()) ?? ""
        self.minimaxCookieLoading = false
        self.minimaxCookieLoaded = true
    }

    func ensureAugmentCookieLoaded() {
        guard !self.augmentCookieLoaded else { return }
        self.augmentCookieLoading = true
        self.augmentCookieHeader = (try? self.augmentCookieStore.loadCookieHeader()) ?? ""
        self.augmentCookieLoading = false
        self.augmentCookieLoaded = true
    }

    func ensureCopilotAPITokenLoaded() {
        guard !self.copilotTokenLoaded else { return }
        self.copilotTokenLoading = true
        self.copilotAPIToken = (try? self.copilotTokenStore.loadToken()) ?? ""
        self.copilotTokenLoading = false
        self.copilotTokenLoaded = true
    }
}

enum LaunchAtLoginManager {
    @MainActor
    static func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13, *) else { return }
        let service = SMAppService.mainApp
        if enabled {
            try? service.register()
        } else {
            try? service.unregister()
        }
    }
}
