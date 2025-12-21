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
        case refresh
        case dashboard
        case statusPage
        case switchAccount(UsageProvider)
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
        account: AccountInfo) -> MenuDescriptor
    {
        var sections: [Section] = []

        switch provider {
        case .codex?:
            sections.append(Self.usageSection(for: .codex, store: store))
            sections.append(Self.accountSection(
                claude: nil,
                codex: store.snapshot(for: .codex),
                account: account,
                preferClaude: false))
        case .claude?:
            sections.append(Self.usageSection(for: .claude, store: store))
            sections.append(Self.accountSection(
                claude: store.snapshot(for: .claude),
                codex: store.snapshot(for: .codex),
                account: account,
                preferClaude: true))
        case .gemini?:
            sections.append(Self.usageSection(for: .gemini, store: store))
            sections.append(Self.accountSection(
                claude: nil,
                codex: nil,
                account: account,
                preferClaude: false))
        case nil:
            var addedUsage = false
            for enabledProvider in store.enabledProviders() {
                sections.append(Self.usageSection(for: enabledProvider, store: store))
                addedUsage = true
            }
            if addedUsage {
                sections.append(Self.accountSection(
                    claude: store.snapshot(for: .claude),
                    codex: store.snapshot(for: .codex),
                    account: account,
                    preferClaude: store.isEnabled(.claude)))
            } else {
                sections.append(Section(entries: [.text("No usage configured.", .secondary)]))
            }
        }

        sections.append(Self.actionsSection(for: provider, store: store))
        sections.append(Self.metaSection())

        return MenuDescriptor(sections: sections)
    }

    private static func usageSection(for provider: UsageProvider, store: UsageStore) -> Section {
        let meta = store.metadata(for: provider)
        var entries: [Entry] = []
        let headlineText: String = {
            if let ver = Self.versionNumber(for: provider, store: store) { return "\(meta.displayName) \(ver)" }
            return meta.displayName
        }()
        entries.append(.text(headlineText, .headline))

        if let snap = store.snapshot(for: provider) {
            Self.appendRateWindow(entries: &entries, title: meta.sessionLabel, window: snap.primary)
            if let weekly = snap.secondary {
                Self.appendRateWindow(entries: &entries, title: meta.weeklyLabel, window: weekly)
                if let paceText = UsagePaceText.weekly(provider: provider, window: weekly) {
                    entries.append(.text(paceText, .secondary))
                }
            } else if provider == .claude {
                entries.append(.text("Weekly usage unavailable for this account.", .secondary))
            }
            if meta.supportsOpus, let opus = snap.tertiary {
                Self.appendRateWindow(entries: &entries, title: meta.opusLabel ?? "Sonnet", window: opus)
            }

        } else {
            entries.append(.text("No usage yet", .secondary))
            if let err = store.error(for: provider), !err.isEmpty {
                let title = UsageFormatter.truncatedSingleLine(err, max: 80)
                entries.append(.action(title, .copyError(err)))
            }
        }

        if meta.supportsCredits, provider == .codex {
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

    /// Builds the account section.
    /// - Claude snapshot is preferred when `preferClaude` is true.
    /// - Otherwise Codex snapshot wins; falls back to stored auth info.
    private static func accountSection(
        claude: UsageSnapshot?,
        codex: UsageSnapshot?,
        account: AccountInfo,
        preferClaude: Bool) -> Section
    {
        var entries: [Entry] = []
        let emailFromClaude = claude?.accountEmail
        let emailFromCodex = codex?.accountEmail
        let planFromClaude = claude?.loginMethod
        let planFromCodex = codex?.loginMethod

        // Email: Claude wins when requested; otherwise Codex snapshot then auth.json fallback.
        let emailText: String = {
            if preferClaude, let e = emailFromClaude, !e.isEmpty { return e }
            if let e = emailFromCodex, !e.isEmpty { return e }
            if let codexEmail = account.email, !codexEmail.isEmpty { return codexEmail }
            if let e = emailFromClaude, !e.isEmpty { return e }
            return "Unknown"
        }()
        entries.append(.text("Account: \(emailText)", .secondary))

        // Plan: show only Claude plan when in Claude mode; otherwise Codex plan.
        if preferClaude {
            if let plan = planFromClaude, !plan.isEmpty {
                entries.append(.text("Plan: \(AccountFormatter.plan(plan))", .secondary))
            }
        } else if let plan = planFromCodex, !plan.isEmpty {
            entries.append(.text("Plan: \(AccountFormatter.plan(plan))", .secondary))
        } else if let plan = account.plan, !plan.isEmpty {
            entries.append(.text("Plan: \(AccountFormatter.plan(plan))", .secondary))
        }

        return Section(entries: entries)
    }

    private static func actionsSection(for provider: UsageProvider?, store: UsageStore) -> Section {
        var entries: [Entry] = [
            .action("Refresh Now", .refresh),
        ]

        // Show "Add Account" if no account, "Switch Account" if logged in
        let loginAction = self.switchAccountTarget(for: provider, store: store)
        let hasAccount = self.hasAccount(for: provider, store: store)
        let accountLabel = hasAccount ? "Switch Account..." : "Add Account..."
        entries.append(.action(accountLabel, loginAction))

        entries.append(contentsOf: [
            .action("Usage Dashboard", .dashboard),
            .action("Status Page", .statusPage),
        ])

        if let statusLine = self.statusLine(for: provider, store: store) {
            entries.append(.text(statusLine, .secondary))
        }

        return Section(entries: entries)
    }

    private static func metaSection() -> Section {
        Section(entries: [
            .action("Settings...", .settings),
            .action("About CodexBar", .about),
            .action("Quit", .quit),
        ])
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

    private static func hasAccount(for provider: UsageProvider?, store: UsageStore) -> Bool {
        let target = provider ?? store.enabledProviders().first ?? .codex
        return store.snapshot(for: target)?.accountEmail != nil
    }

    private static func appendRateWindow(entries: inout [Entry], title: String, window: RateWindow) {
        let line = UsageFormatter
            .usageLine(remaining: window.remainingPercent, used: window.usedPercent)
        entries.append(.text("\(title): \(line)", .primary))
        if let date = window.resetsAt {
            let countdown = UsageFormatter.resetCountdownDescription(from: date)
            entries.append(.text("Resets \(countdown)", .secondary))
        } else if let reset = window.resetDescription {
            entries.append(.text(Self.resetLine(reset), .secondary))
        }
    }

    private static func resetLine(_ reset: String) -> String {
        let trimmed = reset.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("resets") { return trimmed }
        return "Resets \(trimmed)"
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
        case .settings, .about, .quit:
            nil
        case .refresh: MenuDescriptor.MenuActionSystemImage.refresh.rawValue
        case .dashboard: MenuDescriptor.MenuActionSystemImage.dashboard.rawValue
        case .statusPage: MenuDescriptor.MenuActionSystemImage.statusPage.rawValue
        case .switchAccount: MenuDescriptor.MenuActionSystemImage.switchAccount.rawValue
        case .copyError: MenuDescriptor.MenuActionSystemImage.copyError.rawValue
        }
    }
}
