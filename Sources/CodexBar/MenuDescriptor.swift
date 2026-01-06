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
        updateReady: Bool) -> MenuDescriptor
    {
        var sections: [Section] = []

        switch provider {
        case .codex?:
            sections.append(Self.usageSection(for: .codex, store: store, settings: settings))
            if let accountSection = Self.accountSection(
                for: .codex,
                store: store,
                settings: settings,
                account: account)
            {
                sections.append(accountSection)
            }
        case .claude?:
            sections.append(Self.usageSection(for: .claude, store: store, settings: settings))
            if let accountSection = Self.accountSection(
                for: .claude,
                store: store,
                settings: settings,
                account: account)
            {
                sections.append(accountSection)
            }
        case let provider?:
            sections.append(Self.usageSection(for: provider, store: store, settings: settings))
            if let accountSection = Self.accountSection(
                for: provider,
                store: store,
                settings: settings,
                account: account)
            {
                sections.append(accountSection)
            }
        case nil:
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

        let actions = Self.actionsSection(for: provider, store: store, account: account)
        if !actions.entries.isEmpty {
            sections.append(actions)
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
                Self.appendRateWindow(
                    entries: &entries,
                    title: meta.sessionLabel,
                    window: primary,
                    resetStyle: resetStyle)
            }
            if let weekly = snap.secondary {
                Self.appendRateWindow(
                    entries: &entries,
                    title: meta.weeklyLabel,
                    window: weekly,
                    resetStyle: resetStyle)
                if let paceText = UsagePaceText.weekly(provider: provider, window: weekly) {
                    entries.append(.text(paceText, .secondary))
                }
            } else if provider == .claude {
                entries.append(.text("Weekly usage unavailable for this account.", .secondary))
            }
            if meta.supportsOpus, let opus = snap.tertiary {
                Self.appendRateWindow(
                    entries: &entries,
                    title: meta.opusLabel ?? "Sonnet",
                    window: opus,
                    resetStyle: resetStyle)
            }

            if let cost = snap.providerCost {
                if cost.currencyCode == "Quota" {
                    let used = String(format: "%.0f", cost.used)
                    let limit = String(format: "%.0f", cost.limit)
                    entries.append(.text("Quota: \(used) / \(limit)", .primary))
                } else if settings.showOptionalCreditsAndExtraUsage, provider == .claude {
                    let used = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
                    let limit = UsageFormatter.currencyString(cost.limit, currencyCode: cost.currencyCode)
                    entries.append(.text("Extra usage: \(used) / \(limit)", .primary))
                } else if provider == .cursor {
                    let used = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
                    if cost.limit > 0 {
                        let limitStr = UsageFormatter.currencyString(cost.limit, currencyCode: cost.currencyCode)
                        entries.append(.text("On-Demand: \(used) / \(limitStr)", .primary))
                    } else {
                        entries.append(.text("On-Demand: \(used)", .primary))
                    }
                }
            }
        } else {
            entries.append(.text("No usage yet", .secondary))
        }

        if settings.showOptionalCreditsAndExtraUsage,
           meta.supportsCredits,
           provider == .codex
        {
            if let credits = store.credits {
                entries.append(.text("Credits: \(UsageFormatter.creditsString(from: credits.remaining))", .primary))
                if let latest = credits.events.first {
                    entries.append(.text("Last spend: \(UsageFormatter.creditEventSummary(latest))", .secondary))
                }
            } else {
                let hint = store.lastCreditsError ?? meta.creditsHint
                entries.append(.text(hint, .secondary))
            }
        }

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
        let shouldOpenClaudeTerminal = Self.shouldOpenTerminalForClaudeOAuthError(
            provider: targetProvider,
            store: store)

        // Show "Add Account" if no account, "Switch Account" if logged in
        if let targetProvider,
           ProviderCatalog.implementation(for: targetProvider)?.supportsLoginFlow == true
        {
            let loginAction = self.switchAccountTarget(for: provider, store: store)
            let hasAccount = self.hasAccount(for: provider, store: store, account: account)
            let accountLabel: String
            let accountAction: MenuAction
            if shouldOpenClaudeTerminal {
                accountLabel = "Open Terminal"
                accountAction = .openTerminal(command: "claude")
            } else {
                accountLabel = hasAccount ? "Switch Account..." : "Add Account..."
                accountAction = loginAction
            }
            entries.append(.action(accountLabel, accountAction))
        }

        // Show Augment session management options
        if let targetProvider, targetProvider == .augment {
            // Show login prompt for session/cookie errors
            if let error = store.error(for: .augment) {
                if error.contains("session has expired") ||
                    error.contains("No Augment session cookie found")
                {
                    entries.append(.action(
                        "Open Augment (Log Out & Back In)",
                        .loginToProvider(url: "https://app.augmentcode.com")))
                }
            }
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

    private static func shouldOpenTerminalForClaudeOAuthError(
        provider: UsageProvider?,
        store: UsageStore) -> Bool
    {
        guard provider == .claude else { return false }
        guard store.error(for: .claude) != nil else { return false }
        let attempts = store.fetchAttempts(for: .claude)
        if attempts.contains(where: { $0.kind == .oauth && ($0.errorDescription?.isEmpty == false) }) {
            return true
        }
        if let error = store.error(for: .claude)?.lowercased(), error.contains("oauth") {
            return true
        }
        return false
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
        resetStyle: ResetTimeDisplayStyle)
    {
        let line = UsageFormatter
            .usageLine(remaining: window.remainingPercent, used: window.usedPercent)
        entries.append(.text("\(title): \(line)", .primary))
        if let reset = UsageFormatter.resetLine(for: window, style: resetStyle) {
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

    static func email(_ text: String) -> String { text }
}

extension MenuDescriptor.MenuAction {
    var systemImageName: String? {
        switch self {
        case .installUpdate, .settings, .about, .quit:
            nil
        case .refresh: MenuDescriptor.MenuActionSystemImage.refresh.rawValue
        case .dashboard: MenuDescriptor.MenuActionSystemImage.dashboard.rawValue
        case .statusPage: MenuDescriptor.MenuActionSystemImage.statusPage.rawValue
        case .switchAccount: MenuDescriptor.MenuActionSystemImage.switchAccount.rawValue
        case .openTerminal: MenuDescriptor.MenuActionSystemImage.openTerminal.rawValue
        case .loginToProvider: MenuDescriptor.MenuActionSystemImage.loginToProvider.rawValue
        case .copyError: MenuDescriptor.MenuActionSystemImage.copyError.rawValue
        }
    }
}
