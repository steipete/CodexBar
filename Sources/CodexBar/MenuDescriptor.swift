import CodexBarCore
import Foundation

@MainActor
struct MenuDescriptor {
    struct Section {
        var entries: [Entry]
    }

    enum Entry {
        case text(String, TextStyle)
        case action(String, MenuAction)
        case divider
    }

    enum MenuActionSystemImage: String {
        case refresh = "arrow.clockwise"
        case dashboard = "chart.bar"
        case statusPage = "waveform.path.ecg"
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

    enum MenuAction {
        case installUpdate
        case refresh
        case refreshAugmentSession
        case dashboard
        case statusPage
        case switchAccount(UsageProvider)
        case openTerminal(command: String)
        case loginToProvider(url: String)
        case settings
        case about
        case quit
        case copyError(String)
    }

    var sections: [Section]

    static func build(
        provider: UsageProvider?,
        store: UsageStore,
        settings: SettingsStore,
        account: AccountInfo,
        updateReady: Bool,
        includeContextualActions: Bool = true) -> MenuDescriptor
    {
        var sections: [Section] = []

        if let provider {
            sections.append(Self.usageSection(for: provider, store: store, settings: settings))
            if let accountSection = Self.accountSection(
                for: provider,
                store: store,
                settings: settings,
                account: account)
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
                   let accountSection = Self.accountSection(
                       for: accountProvider,
                       store: store,
                       settings: settings,
                       account: account)
                {
                    sections.append(accountSection)
                }
            } else {
                sections.append(Section(entries: [.text("No usage configured.", .secondary)]))
            }
        }

        if includeContextualActions {
            let actions = Self.actionsSection(for: provider, store: store, account: account)
            if !actions.entries.isEmpty {
                sections.append(actions)
            }
        }
        sections.append(Self.metaSection(updateReady: updateReady))

        return MenuDescriptor(sections: sections)
    }

    private static func usageSection(
        for provider: UsageProvider,
        store: UsageStore,
        settings: SettingsStore) -> Section
    {
        let meta = store.metadata(for: provider)
        var entries: [Entry] = []
        let headlineText: String = {
            if let ver = Self.versionNumber(for: provider, store: store) { return "\(meta.displayName) \(ver)" }
            return meta.displayName
        }()
        entries.append(.text(headlineText, .headline))

        if let snap = store.snapshot(for: provider) {
            let resetStyle = settings.resetTimeDisplayStyle
            if let primary = snap.primary {
                let primaryWindow = if provider == .warp {
                    // Warp primary uses resetDescription for non-reset detail (e.g., "Unlimited", "X/Y credits").
                    // Avoid rendering it as a "Resets ..." line.
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
                    title: meta.sessionLabel,
                    window: primaryWindow,
                    resetStyle: resetStyle,
                    showUsed: settings.usageBarsShowUsed)
                if provider == .warp,
                   let detail = primary.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !detail.isEmpty
                {
                    entries.append(.text(detail, .secondary))
                }
            }
            if let weekly = snap.secondary {
                let weeklyResetOverride: String? = {
                    guard provider == .warp else { return nil }
                    let detail = weekly.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (detail?.isEmpty ?? true) ? nil : detail
                }()
                Self.appendRateWindow(
                    entries: &entries,
                    title: meta.weeklyLabel,
                    window: weekly,
                    resetStyle: resetStyle,
                    showUsed: settings.usageBarsShowUsed,
                    resetOverride: weeklyResetOverride)
                if let paceSummary = UsagePaceText.weeklySummary(provider: provider, window: weekly) {
                    entries.append(.text(paceSummary, .secondary))
                }
            }
            if meta.supportsOpus, let opus = snap.tertiary {
                Self.appendRateWindow(
                    entries: &entries,
                    title: meta.opusLabel ?? "Sonnet",
                    window: opus,
                    resetStyle: resetStyle,
                    showUsed: settings.usageBarsShowUsed)
            }

            if let cost = snap.providerCost {
                if cost.currencyCode == "Quota" {
                    let used = String(format: "%.0f", cost.used)
                    let limit = String(format: "%.0f", cost.limit)
                    entries.append(.text("Quota: \(used) / \(limit)", .primary))
                }
            }
        } else {
            entries.append(.text("No usage yet", .secondary))
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
        let planText = snapshot?.loginMethod(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let redactedEmail = PersonalInfoRedactor.redactEmail(emailText, isEnabled: hidePersonalInfo)

        if let emailText, !emailText.isEmpty {
            entries.append(.text("Account: \(redactedEmail)", .secondary))
        }
        if let planText, !planText.isEmpty {
            entries.append(.text("Plan: \(AccountFormatter.plan(planText))", .secondary))
        }

        if metadata.usesAccountFallback {
            if emailText?.isEmpty ?? true, let fallbackEmail = fallback.email, !fallbackEmail.isEmpty {
                let redacted = PersonalInfoRedactor.redactEmail(fallbackEmail, isEnabled: hidePersonalInfo)
                entries.append(.text("Account: \(redacted)", .secondary))
            }
            if planText?.isEmpty ?? true, let fallbackPlan = fallback.plan, !fallbackPlan.isEmpty {
                entries.append(.text("Plan: \(AccountFormatter.plan(fallbackPlan))", .secondary))
            }
        }

        return entries
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
        account: AccountInfo) -> Section
    {
        var entries: [Entry] = []
        let targetProvider = provider ?? store.enabledProviders().first
        let metadata = targetProvider.map { store.metadata(for: $0) }
        let loginContext = targetProvider.map {
            ProviderMenuLoginContext(
                provider: $0,
                store: store,
                settings: store.settings,
                account: account)
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
                let hasAccount = self.hasAccount(for: provider, store: store, account: account)
                let accountLabel = hasAccount ? "Switch Account..." : "Add Account..."
                entries.append(.action(accountLabel, loginAction))
            }
        }

        if let targetProvider {
            let actionContext = ProviderMenuActionContext(
                provider: targetProvider,
                store: store,
                settings: store.settings,
                account: account)
            ProviderCatalog.implementation(for: targetProvider)?
                .appendActionMenuEntries(context: actionContext, entries: &entries)
        }

        if metadata?.dashboardURL != nil {
            entries.append(.action("Usage Dashboard", .dashboard))
        }
        if metadata?.statusPageURL != nil || metadata?.statusLinkURL != nil {
            entries.append(.action("Status Page", .statusPage))
        }

        if let statusLine = self.statusLine(for: provider, store: store) {
            entries.append(.text(statusLine, .secondary))
        }

        return Section(entries: entries)
    }

    private static func metaSection(updateReady: Bool) -> Section {
        var entries: [Entry] = []
        if updateReady {
            entries.append(.action("Update ready, restart now?", .installUpdate))
        }
        entries.append(contentsOf: [
            .action("Settings...", .settings),
            .action("About CodexBar", .about),
            .action("Quit", .quit),
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
        if let provider { return .switchAccount(provider) }
        if let enabled = store.enabledProviders().first { return .switchAccount(enabled) }
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
    static func plan(_ text: String) -> String {
        let cleaned = UsageFormatter.cleanPlanName(text)
        return cleaned.isEmpty ? text : cleaned
    }

    static func email(_ text: String) -> String {
        text
    }
}

extension MenuDescriptor.MenuAction {
    var systemImageName: String? {
        switch self {
        case .installUpdate, .settings, .about, .quit:
            nil
        case .refresh: MenuDescriptor.MenuActionSystemImage.refresh.rawValue
        case .refreshAugmentSession: MenuDescriptor.MenuActionSystemImage.refresh.rawValue
        case .dashboard: MenuDescriptor.MenuActionSystemImage.dashboard.rawValue
        case .statusPage: MenuDescriptor.MenuActionSystemImage.statusPage.rawValue
        case .switchAccount: MenuDescriptor.MenuActionSystemImage.switchAccount.rawValue
        case .openTerminal: MenuDescriptor.MenuActionSystemImage.openTerminal.rawValue
        case .loginToProvider: MenuDescriptor.MenuActionSystemImage.loginToProvider.rawValue
        case .copyError: MenuDescriptor.MenuActionSystemImage.copyError.rawValue
        }
    }
}
