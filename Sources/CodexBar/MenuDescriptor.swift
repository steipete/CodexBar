import CodexBarCore
import Foundation

@MainActor
struct MenuDescriptor {
    struct SubmenuItem: Equatable {
        let title: String
        let action: MenuAction?
        let isEnabled: Bool
        let isChecked: Bool

        init(title: String, action: MenuAction?, isEnabled: Bool = true, isChecked: Bool = false) {
            self.title = title
            self.action = action
            self.isEnabled = isEnabled
            self.isChecked = isChecked
        }
    }

    struct Section {
        var entries: [Entry]
    }

    enum Entry {
        case text(String, TextStyle)
        case action(String, MenuAction)
        case unavailable(String, String?)
        case submenu(String, String?, [SubmenuItem])
        case divider

        var isActionable: Bool {
            switch self {
            case .action, .submenu, .unavailable: true
            case .text, .divider: false
            }
        }
    }

    enum MenuActionSystemImage: String {
        case installUpdate = "arrow.down.circle"
        case refresh = "arrow.clockwise"
        case dashboard = "chart.xyaxis.line"
        case statusPage = "waveform.path.ecg"
        case changelog = "list.bullet.rectangle"
        case addAccount = "plus"
        case systemAccount = "person.crop.circle"
        case switchAccount = "key"
        case openTerminal = "terminal"
        case loginToProvider = "arrow.right.square"
        case settings = "gearshape"
        case about = "info.circle"
        case quit = "xmark.rectangle"
        case copyError = "doc.on.doc"
    }

    enum TextStyle {
        case headline
        case primary
        case secondary
    }

    enum MenuAction: Equatable {
        case installUpdate
        case refresh
        case refreshAugmentSession
        case dashboard
        case statusPage
        case changelog
        case addCodexAccount
        case requestCodexSystemPromotion(UUID)
        case addProviderAccount(UsageProvider)
        case switchAccount(UsageProvider)
        case openTerminal(command: String)
        case loginToProvider(url: String)
        case settings
        case about
        case quit
        case copyError(String)
        case focusAgentSession(AgentSession, remoteHost: String?)
    }

    var sections: [Section]

    static func build(
        provider: UsageProvider?,
        store: UsageStore,
        settings: SettingsStore,
        account: AccountInfo,
        managedCodexAccountCoordinator: ManagedCodexAccountCoordinator? = nil,
        codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator? = nil,
        updateReady: Bool,
        includeContextualActions: Bool = true,
        agentSessionsEnabled: Bool = false,
        agentSessionLabelStyle: AgentSessionLabelStyle = .project,
        localAgentSessions: [AgentSession] = [],
        remoteAgentHosts: [RemoteSessionHostResult] = [],
        now: Date = Date()) -> MenuDescriptor
    {
        var sections: [Section] = []

        if let provider {
            let fallbackAccount = store.accountInfo(for: provider)
            sections.append(Self.usageSection(for: provider, store: store, settings: settings))
            if let accountSection = Self.accountSection(
                for: provider,
                store: store,
                settings: settings,
                account: fallbackAccount)
            {
                sections.append(accountSection)
            }
        } else {
            var addedUsage = false

            for enabledProvider in store.enabledProviders() {
                sections.append(Self.usageSection(for: enabledProvider, store: store, settings: settings))
                addedUsage = true
            }
            if addedUsage {
                if let accountProvider = Self.accountProviderForCombined(store: store),
                   let fallbackAccount = Optional(store.accountInfo(for: accountProvider)),
                   let accountSection = Self.accountSection(
                       for: accountProvider,
                       store: store,
                       settings: settings,
                       account: fallbackAccount)
                {
                    sections.append(accountSection)
                }
            } else {
                sections.append(Section(entries: [.text(L("No usage configured."), .secondary)]))
            }
        }

        if includeContextualActions {
            let actions = Self.actionsSection(
                for: provider,
                store: store,
                account: account,
                managedCodexAccountCoordinator: managedCodexAccountCoordinator,
                codexAccountPromotionCoordinator: codexAccountPromotionCoordinator)
            if !actions.entries.isEmpty {
                sections.append(actions)
            }
        }
        if agentSessionsEnabled {
            sections.append(Self.agentSessionsSection(
                localSessions: localAgentSessions,
                remoteHosts: remoteAgentHosts,
                labelStyle: agentSessionLabelStyle,
                now: now))
        }
        sections.append(Self.metaSection(updateReady: updateReady))

        return MenuDescriptor(sections: sections)
    }

    static func agentSessionsSection(
        localSessions: [AgentSession],
        remoteHosts: [RemoteSessionHostResult],
        labelStyle: AgentSessionLabelStyle = .project,
        now: Date = Date()) -> Section
    {
        let totalCount = localSessions.count + remoteHosts.reduce(0) { $0 + $1.sessions.count }
        var entries: [Entry] = [.text("Agent Sessions (\(totalCount))", .headline)]

        for session in localSessions {
            entries.append(.action(
                self.agentSessionRowTitle(session, labelStyle: labelStyle, now: now),
                .focusAgentSession(session, remoteHost: nil)))
        }
        for remoteHost in remoteHosts {
            if let error = remoteHost.error {
                entries.append(.unavailable("\(remoteHost.host) — unreachable", error))
                continue
            }
            entries.append(.text("\(remoteHost.host) — \(remoteHost.sessions.count)", .secondary))
            for session in remoteHost.sessions {
                entries.append(.action(
                    self.agentSessionRowTitle(session, labelStyle: labelStyle, now: now),
                    .focusAgentSession(session, remoteHost: remoteHost.host)))
            }
        }
        if totalCount == 0 {
            entries.append(.unavailable("No agent sessions found", nil))
        }
        return Section(entries: entries)
    }

    private static func agentSessionRowTitle(
        _ session: AgentSession,
        labelStyle: AgentSessionLabelStyle,
        now: Date) -> String
    {
        let state = session.state == .active ? "●" : "○"
        let providerGlyph = session.provider == .codex ? "⌘" : "✦"
        let label = labelStyle.label(for: session)
        return "\(state) \(providerGlyph) \(label) — \(session.provider.rawValue) · " +
            "\(session.source.rawValue) · \(self.agentSessionAge(session, now: now))"
    }

    private static func agentSessionAge(_ session: AgentSession, now: Date) -> String {
        guard let activity = session.lastActivityAt ?? session.startedAt else { return "now" }
        let seconds = max(0, Int(now.timeIntervalSince(activity)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m"
        }
        if seconds < 86400 {
            return "\(seconds / 3600)h"
        }
        return "\(seconds / 86400)d"
    }

    private static func usageSection(
        for provider: UsageProvider,
        store: UsageStore,
        settings: SettingsStore) -> Section
    {
        let meta = store.metadata(for: provider)
        var entries: [Entry] = []
        let headlineText: String = {
            if let ver = Self.versionNumber(for: provider, store: store) {
                return "\(meta.displayName) \(ver)"
            }
            return meta.displayName
        }()
        entries.append(.text(headlineText, .headline))

        if let snap = store.snapshot(for: provider) {
            let resetStyle = settings.resetTimeDisplayStyle
            let labels = Self.rateWindowLabels(provider: provider, metadata: meta, snapshot: snap)
            if let primary = snap.primary {
                let primaryDetail = primary.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                let primaryDescriptionIsDetail = provider == .warp || provider == .kilo || provider == .abacus ||
                    provider == .deepseek || provider == .deepinfra || provider == .neuralwatt ||
                    provider == .azureopenai || provider == .mimo || provider == .qoder || provider == .sub2api
                let primaryWindow = if primaryDescriptionIsDetail {
                    // Some providers use resetDescription for non-reset detail
                    // (e.g., "Unlimited", "X/Y credits"). Avoid rendering it as a "Resets ..." line.
                    RateWindow(
                        usedPercent: primary.usedPercent,
                        windowMinutes: primary.windowMinutes,
                        resetsAt: primary.resetsAt,
                        resetDescription: nil)
                } else {
                    primary
                }
                Self.appendRateWindow(
                    entries: &entries,
                    title: labels.primary,
                    window: primaryWindow,
                    resetStyle: resetStyle,
                    showUsed: settings.usageBarsShowUsed)
                if primaryDescriptionIsDetail,
                   let primaryDetail,
                   !primaryDetail.isEmpty
                {
                    entries.append(.text(primaryDetail, .secondary))
                }
                if provider == .crof,
                   primary.resetsAt != nil,
                   let detail = primary.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !detail.isEmpty
                {
                    entries.append(.text(detail, .secondary))
                }
                if provider == .abacus,
                   let pace = store.weeklyPace(provider: provider, window: primary)
                {
                    let paceSummary = UsagePaceText.weeklySummary(provider: provider, pace: pace)
                    entries.append(.text(paceSummary, .secondary))
                }
                if let paceSummary = UsagePaceText.sessionSummary(provider: provider, window: primary) {
                    entries.append(.text(paceSummary, .secondary))
                }
            }
            if let weekly = snap.secondary {
                let weeklyResetOverride: String? = {
                    guard provider == .warp || provider == .kilo || provider == .perplexity || provider == .crof ||
                        provider == .sub2api
                    else { return nil }
                    let detail = weekly.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let detail, !detail.isEmpty else { return nil }
                    if provider == .kilo, weekly.resetsAt != nil {
                        return nil
                    }
                    return detail
                }()
                Self.appendRateWindow(
                    entries: &entries,
                    title: labels.secondary,
                    window: weekly,
                    resetStyle: resetStyle,
                    showUsed: settings.usageBarsShowUsed,
                    resetOverride: weeklyResetOverride)
                if provider == .kilo,
                   weekly.resetsAt != nil,
                   let detail = weekly.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !detail.isEmpty
                {
                    entries.append(.text(detail, .secondary))
                }
                if let pace = store.weeklyPace(provider: provider, window: weekly) {
                    let paceSummary = UsagePaceText.weeklySummary(provider: provider, pace: pace)
                    entries.append(.text(paceSummary, .secondary))
                }
            }
            if labels.showsTertiary, let opus = snap.tertiary {
                // Perplexity purchased credits don't reset; show the balance as plain text.
                let opusResetOverride: String? = provider == .perplexity || provider == .sub2api
                    ? opus.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil
                Self.appendRateWindow(
                    entries: &entries,
                    title: labels.tertiary,
                    window: opus,
                    resetStyle: resetStyle,
                    showUsed: settings.usageBarsShowUsed,
                    resetOverride: opusResetOverride)
            }

            Self.appendProviderUsageSummaries(
                entries: &entries,
                snapshot: snap,
                showOptionalUsage: settings.showOptionalCreditsAndExtraUsage)
            if snap.rateLimitsUnavailable(for: provider) {
                entries.append(.text(L("Limits not available"), .secondary))
            }
        } else if !store.isStale(provider: provider),
                  store.knownLimitsAvailability(for: provider)?.isUnavailable == true
        {
            entries.append(.text(L("Limits not available"), .secondary))
        } else {
            entries.append(.text(L("No usage yet"), .secondary))
        }

        let usageContext = ProviderMenuUsageContext(
            provider: provider,
            store: store,
            settings: settings,
            metadata: meta,
            snapshot: store.snapshot(for: provider))
        ProviderCatalog.implementation(for: provider)?
            .appendUsageMenuEntries(context: usageContext, entries: &entries)

        return Section(entries: entries)
    }

    private static func appendProviderUsageSummaries(
        entries: inout [Entry],
        snapshot: UsageSnapshot,
        showOptionalUsage: Bool)
    {
        if let cost = snapshot.providerCost {
            if cost.currencyCode == "Quota" {
                let used = String(format: "%.0f", cost.used)
                let limit = String(format: "%.0f", cost.limit)
                entries.append(.text("\(L("Quota")): \(used) / \(limit)", .primary))
            }
        }
        if let openAIAPIUsage = snapshot.openAIAPIUsage {
            Self.appendOpenAIAPIUsageSummary(entries: &entries, usage: openAIAPIUsage)
        }
        if let claudeAdminAPIUsage = snapshot.claudeAdminAPIUsage {
            Self.appendClaudeAdminAPIUsageSummary(entries: &entries, usage: claudeAdminAPIUsage)
        }
        if let openRouterUsage = snapshot.openRouterUsage {
            Self.appendOpenRouterUsageSummary(entries: &entries, usage: openRouterUsage)
        }
        if let clawRouterUsage = snapshot.clawRouterUsage {
            entries.append(.text(
                "\(UsageFormatter.tokenCountString(clawRouterUsage.requestCount)) \(L("requests")) · " +
                    "\(UsageFormatter.tokenCountString(clawRouterUsage.totalTokens)) \(L("tokens"))",
                .secondary))
            if !clawRouterUsage.providers.isEmpty {
                let mix = clawRouterUsage.providers.prefix(5)
                    .map { "\($0.provider): \(UsageFormatter.tokenCountString($0.requestCount))" }
                    .joined(separator: " · ")
                entries.append(.text("Routed providers: \(mix)", .secondary))
            }
        }
        if let wayfinderUsage = snapshot.wayfinderUsage {
            Self.appendWayfinderUsageSummary(entries: &entries, usage: wayfinderUsage)
        }
        if let poeUsage = snapshot.poeUsage, !poeUsage.daily.isEmpty {
            Self.appendPoeUsageSummary(entries: &entries, usage: poeUsage)
        }
        if let mistralUsage = snapshot.mistralUsage, !mistralUsage.daily.isEmpty {
            Self.appendMistralUsageSummary(entries: &entries, usage: mistralUsage)
        }
        if let mimoUsage = snapshot.mimoUsage {
            entries.append(.text("\(L("Balance")): \(mimoUsage.balanceDetail)", .primary))
        }
        // Sakana pay-as-you-go is optional data gated by "Show optional credits and extra usage".
        // Gate the render on the setting too, not just the fetch: toggling the setting off only
        // rebuilds the menu, it does not immediately refetch, so a previously-populated
        // sakanaPayAsYouGo would otherwise linger in the cached snapshot until the next refresh.
        if showOptionalUsage, let sakanaPayAsYouGo = snapshot.sakanaPayAsYouGo {
            entries.append(.text("\(L("Balance")): \(sakanaPayAsYouGo.balanceDetail)", .primary))
            if let periodUsageTotal = sakanaPayAsYouGo.periodUsageTotal {
                entries.append(.text(
                    "\(L("Usage")): \(UsageFormatter.usdString(periodUsageTotal))",
                    .secondary))
            }
        }
    }

    private static func accountSection(
        for provider: UsageProvider,
        store: UsageStore,
        settings: SettingsStore,
        account: AccountInfo) -> Section?
    {
        let snapshot = store.snapshot(for: provider)
        let metadata = store.metadata(for: provider)
        let entries = Self.accountEntries(
            provider: provider,
            snapshot: snapshot,
            metadata: metadata,
            fallback: account,
            hidePersonalInfo: settings.hidePersonalInfo)
        guard !entries.isEmpty else { return nil }
        return Section(entries: entries)
    }

    private static func accountEntries(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        metadata: ProviderMetadata,
        fallback: AccountInfo,
        hidePersonalInfo: Bool) -> [Entry]
    {
        var entries: [Entry] = []
        let emailText = snapshot?.accountEmail(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethodText = snapshot?.loginMethod(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let redactedEmail = PersonalInfoRedactor.redactEmail(emailText, isEnabled: hidePersonalInfo)

        if let emailText, !emailText.isEmpty, !redactedEmail.isEmpty {
            entries.append(.text("\(L("Account")): \(redactedEmail)", .secondary))
        }
        if provider == .kiro {
            if let plan = snapshot?.kiroUsage?.displayPlanName,
               !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                entries.append(.text("\(L("Plan")): \(plan)", .secondary))
            }
            if let loginMethodText, !loginMethodText.isEmpty {
                entries.append(.text("\(L("Auth")): \(loginMethodText)", .secondary))
            }
            if let overages = snapshot?.kiroUsage?.overagesStatus,
               !overages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                entries.append(.text("\(L("Overages")): \(overages)", .secondary))
            }
        } else if provider == .kilo {
            let kiloLogin = self.kiloLoginParts(loginMethod: loginMethodText)
            if let pass = kiloLogin.pass {
                entries.append(.text("\(L("Plan")): \(AccountFormatter.plan(pass, provider: provider))", .secondary))
            }
            for detail in kiloLogin.details {
                entries.append(.text("\(L("Activity")): \(detail)", .secondary))
            }
        } else if let loginMethodText, !loginMethodText.isEmpty {
            if provider == .openrouter || provider == .mimo || provider == .poe,
               loginMethodText.localizedCaseInsensitiveContains("balance:")
            {
                let balanceValue = loginMethodText
                    .replacingOccurrences(
                        of: #"(?i)^\s*balance:\s*"#,
                        with: "",
                        options: [.regularExpression])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let value = balanceValue.isEmpty ? loginMethodText : balanceValue
                entries.append(
                    .text("\(L("Balance")): \(AccountFormatter.plan(value, provider: provider))", .secondary))
            } else {
                entries.append(
                    .text(
                        "\(L("Plan")): \(AccountFormatter.plan(loginMethodText, provider: provider))",
                        .secondary))
            }
        }

        if metadata.usesAccountFallback {
            if emailText?.isEmpty ?? true, let fallbackEmail = fallback.email, !fallbackEmail.isEmpty {
                let redacted = PersonalInfoRedactor.redactEmail(fallbackEmail, isEnabled: hidePersonalInfo)
                if !redacted.isEmpty {
                    entries.append(.text("\(L("Account")): \(redacted)", .secondary))
                }
            }
            if loginMethodText?.isEmpty ?? true, let fallbackPlan = fallback.plan, !fallbackPlan.isEmpty {
                entries.append(
                    .text(
                        "\(L("Plan")): \(AccountFormatter.plan(fallbackPlan, provider: provider))",
                        .secondary))
            }
        }

        return entries
    }

    private static func kiloLoginParts(loginMethod: String?) -> (pass: String?, details: [String]) {
        guard let loginMethod else {
            return (nil, [])
        }
        let parts = loginMethod
            .components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return (nil, [])
        }
        let first = parts[0]
        if self.isKiloActivitySegment(first) {
            return (nil, parts)
        }
        return (first, Array(parts.dropFirst()))
    }

    private static func isKiloActivitySegment(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("auto top-up:")
    }

    private static func accountProviderForCombined(store: UsageStore) -> UsageProvider? {
        for provider in store.enabledProviders() {
            let metadata = store.metadata(for: provider)
            if store.snapshot(for: provider)?.identity(for: provider) != nil {
                return provider
            }
            if metadata.usesAccountFallback {
                return provider
            }
        }
        return nil
    }

    private static func actionsSection(
        for provider: UsageProvider?,
        store: UsageStore,
        account: AccountInfo,
        managedCodexAccountCoordinator: ManagedCodexAccountCoordinator?,
        codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator?) -> Section
    {
        var entries: [Entry] = []
        let targetProvider = provider ?? store.enabledProviders().first
        let metadata = targetProvider.map { store.metadata(for: $0) }
        let fallbackAccount = targetProvider.map { store.accountInfo(for: $0) } ?? account
        let loginContext = targetProvider.map {
            ProviderMenuLoginContext(
                provider: $0,
                store: store,
                settings: store.settings,
                account: fallbackAccount)
        }

        // Show "Add Account" if no account, "Switch Account" if logged in
        if let targetProvider,
           let implementation = ProviderCatalog.implementation(for: targetProvider),
           implementation.supportsLoginFlow
        {
            if let loginContext,
               let override = implementation.loginMenuAction(context: loginContext)
            {
                entries.append(.action(override.label, override.action))
            } else {
                let loginAction = self.switchAccountTarget(for: provider, store: store)
                let hasAccount = self.hasAccount(for: provider, store: store, account: fallbackAccount)
                let accountLabel = hasAccount ? L("Switch Account...") : L("Add Account...")
                entries.append(.action(accountLabel, loginAction))
            }
        }

        if let targetProvider {
            let actionContext = ProviderMenuActionContext(
                provider: targetProvider,
                store: store,
                settings: store.settings,
                account: fallbackAccount,
                managedCodexAccountCoordinator: managedCodexAccountCoordinator,
                codexAccountPromotionCoordinator: codexAccountPromotionCoordinator)
            ProviderCatalog.implementation(for: targetProvider)?
                .appendActionMenuEntries(context: actionContext, entries: &entries)
        }

        if metadata?.dashboardURL != nil {
            entries.append(.action(L("Usage Dashboard"), .dashboard))
        }
        if metadata?.statusPageURL != nil || metadata?.statusLinkURL != nil {
            entries.append(.action(L("Status Page"), .statusPage))
        }
        if store.settings.providerChangelogLinksEnabled, metadata?.changelogURL != nil {
            entries.append(.action(L("Changelog"), .changelog))
        }

        if let statusLine = self.statusLine(for: provider, store: store) {
            entries.append(.text(statusLine, .secondary))
        }

        return Section(entries: entries)
    }

    private static func metaSection(updateReady: Bool) -> Section {
        var entries: [Entry] = []
        if updateReady {
            entries.append(.action(L("Update ready, restart now?"), .installUpdate))
        }
        entries.append(contentsOf: [
            .action(L("Refresh"), .refresh),
            .action(L("Settings..."), .settings),
            .action(L("About CodexBar"), .about),
            .action(L("Quit"), .quit),
        ])
        return Section(entries: entries)
    }

    private static func statusLine(for provider: UsageProvider?, store: UsageStore) -> String? {
        let target = provider ?? store.enabledProviders().first
        guard let target,
              let status = store.status(for: target),
              status.indicator != .none else { return nil }

        let description = status.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = description?.isEmpty == false ? description! : status.indicator.label
        if let updated = status.updatedAt {
            let freshness = UsageFormatter.updatedString(from: updated)
            return "\(label) — \(freshness)"
        }
        return label
    }

    private static func switchAccountTarget(for provider: UsageProvider?, store: UsageStore) -> MenuAction {
        if let provider {
            return .switchAccount(provider)
        }
        if let enabled = store.enabledProviders().first {
            return .switchAccount(enabled)
        }
        return .switchAccount(.codex)
    }

    private static func hasAccount(for provider: UsageProvider?, store: UsageStore, account: AccountInfo) -> Bool {
        let target = provider ?? store.enabledProviders().first ?? .codex
        if let email = store.snapshot(for: target)?.accountEmail(for: target),
           !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        let metadata = store.metadata(for: target)
        if metadata.usesAccountFallback,
           let fallback = account.email?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty
        {
            return true
        }
        return false
    }

    private static func rateWindowLabels(
        provider: UsageProvider,
        metadata: ProviderMetadata,
        snapshot: UsageSnapshot) -> (primary: String, secondary: String, tertiary: String, showsTertiary: Bool)
    {
        if provider == .factory, snapshot.tertiary != nil {
            return ("5-hour", L("Weekly"), L("Monthly"), true)
        }
        let primaryLabel = if provider == .grok {
            GrokProviderDescriptor.primaryLabel(window: snapshot.primary) ?? metadata.sessionLabel
        } else if provider == .doubao {
            DoubaoProviderDescriptor.primaryLabel(window: snapshot.primary) ?? metadata.sessionLabel
        } else if provider == .sub2api {
            Sub2APIProviderDescriptor.primaryLabel(details: snapshot.sub2APIUsage) ?? metadata.sessionLabel
        } else {
            metadata.sessionLabel
        }
        return (
            L(primaryLabel),
            L(metadata.weeklyLabel),
            metadata.opusLabel.map(L) ?? L("Sonnet"),
            metadata.supportsOpus)
    }

    private static func appendRateWindow(
        entries: inout [Entry],
        title: String,
        window: RateWindow,
        resetStyle: ResetTimeDisplayStyle,
        showUsed: Bool,
        resetOverride: String? = nil)
    {
        let line = UsageFormatter
            .usageLine(remaining: window.remainingPercent, used: window.usedPercent, showUsed: showUsed)
        entries.append(.text("\(title): \(line)", .primary))
        if let resetOverride {
            entries.append(.text(resetOverride, .secondary))
        } else if let reset = UsageFormatter.resetLine(for: window, style: resetStyle) {
            entries.append(.text(reset, .secondary))
        }
    }

    private static func versionNumber(for provider: UsageProvider, store: UsageStore) -> String? {
        guard let raw = store.version(for: provider) else { return nil }
        let pattern = #"[0-9]+(?:\.[0-9]+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, options: [], range: range),
              let r = Range(match.range, in: raw) else { return nil }
        return String(raw[r])
    }
}

private enum AccountFormatter {
    static func plan(_ text: String, provider: UsageProvider) -> String {
        let cleaned = if provider == .codex {
            CodexPlanFormatting.displayName(text) ?? UsageFormatter.cleanPlanName(text)
        } else {
            UsageFormatter.cleanPlanName(text)
        }
        return cleaned.isEmpty ? text : cleaned
    }

    static func email(_ text: String) -> String {
        text
    }
}

extension MenuDescriptor.MenuAction {
    var systemImageName: String? {
        switch self {
        case .installUpdate: MenuDescriptor.MenuActionSystemImage.installUpdate.rawValue
        case .settings: MenuDescriptor.MenuActionSystemImage.settings.rawValue
        case .about: MenuDescriptor.MenuActionSystemImage.about.rawValue
        case .quit: MenuDescriptor.MenuActionSystemImage.quit.rawValue
        case .refresh: MenuDescriptor.MenuActionSystemImage.refresh.rawValue
        case .refreshAugmentSession: MenuDescriptor.MenuActionSystemImage.refresh.rawValue
        case .dashboard: MenuDescriptor.MenuActionSystemImage.dashboard.rawValue
        case .statusPage: MenuDescriptor.MenuActionSystemImage.statusPage.rawValue
        case .changelog: MenuDescriptor.MenuActionSystemImage.changelog.rawValue
        case .addCodexAccount, .addProviderAccount: MenuDescriptor.MenuActionSystemImage.addAccount.rawValue
        case .requestCodexSystemPromotion:
            nil
        case .switchAccount: MenuDescriptor.MenuActionSystemImage.switchAccount.rawValue
        case .openTerminal: MenuDescriptor.MenuActionSystemImage.openTerminal.rawValue
        case .loginToProvider: MenuDescriptor.MenuActionSystemImage.loginToProvider.rawValue
        case .copyError: MenuDescriptor.MenuActionSystemImage.copyError.rawValue
        case .focusAgentSession:
            nil
        }
    }
}
