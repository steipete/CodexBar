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

    enum TextStyle {
        case headline
        case primary
        case secondary
    }

    enum MenuAction {
        case refresh
        case dashboard
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

        func versionNumber(for provider: UsageProvider) -> String? {
            guard let raw = store.version(for: provider) else { return nil }
            let pattern = #"[0-9]+(?:\.[0-9]+)*"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, options: [], range: range),
                  let r = Range(match.range, in: raw) else { return nil }
            return String(raw[r])
        }

        func usageSection(for provider: UsageProvider, titlePrefix: String) -> Section {
            let meta = store.metadata(for: provider)
            var entries: [Entry] = []
            let headline = { (text: String) in Entry.text("\(meta.displayName) · \(text)", .headline) }

            entries.append(headline(meta.sessionLabel))
            if let snap = store.snapshot(for: provider) {
                entries.append(.text(
                    UsageFormatter.usageLine(remaining: snap.primary.remainingPercent, used: snap.primary.usedPercent),
                    .primary))
                if let reset = snap.primary.resetDescription { entries.append(.text("Resets \(reset)", .secondary)) }

                entries.append(headline(meta.weeklyLabel))
                entries.append(.text(
                    UsageFormatter
                        .usageLine(remaining: snap.secondary.remainingPercent, used: snap.secondary.usedPercent),
                    .primary))
                if let reset = snap.secondary.resetDescription { entries.append(.text("Resets \(reset)", .secondary)) }

                if meta.supportsOpus, let opus = snap.tertiary {
                    entries.append(headline(meta.opusLabel ?? "Opus"))
                    entries.append(.text(
                        UsageFormatter.usageLine(remaining: opus.remainingPercent, used: opus.usedPercent),
                        .primary))
                    if let reset = opus.resetDescription { entries.append(.text("Resets \(reset)", .secondary)) }
                }

                entries.append(.text(UsageFormatter.updatedString(from: snap.updatedAt), .secondary))

                if let org = snap.accountOrganization, !org.isEmpty { entries.append(.text("Org: \(org)", .secondary)) }
                if let plan = snap.loginMethod, !plan.isEmpty { entries.append(.text("Plan: \(plan)", .secondary)) }
                if let email = snap.accountEmail { entries.append(.text("Account: \(email)", .secondary)) }
            } else {
                entries.append(.text("No usage yet", .secondary))
                if let err = store.error(for: provider), !err.isEmpty {
                    entries.append(.action(err, .copyError(err)))
                }
            }

            if meta.supportsCredits, provider == .codex {
                if let credits = store.credits {
                    entries.append(.text("Credits: \(UsageFormatter.creditsString(from: credits.remaining))", .primary))
                    if let latest = credits.events.first {
                        entries.append(.text("Last spend: \(UsageFormatter.creditEventSummary(latest))", .secondary))
                    }
                } else {
                    entries.append(.text(meta.creditsHint, .secondary))
                }
            }
            return Section(entries: entries)
        }

        /// Builds the account section.
        /// - If a Claude snapshot is provided, we only trust its account fields (email/loginMethod).
        ///   This prevents leaking Codex plan/email when the user is looking at Claude.
        /// - If no Claude snapshot is available, fall back to Codex auth info.
        func accountSection(preferred claude: UsageSnapshot?, preferClaude: Bool) -> Section {
            var entries: [Entry] = []
            let emailFromClaude = claude?.accountEmail
            let planFromClaude = claude?.loginMethod
            let providerForMeta: UsageProvider = preferClaude ? .claude : .codex

            // Email: Claude wins when requested; otherwise Codex auth.
            let emailText: String = {
                if preferClaude, let e = emailFromClaude, !e.isEmpty { return e }
                if let codexEmail = account.email, !codexEmail.isEmpty { return codexEmail }
                if let e = emailFromClaude, !e.isEmpty { return e }
                return "Unknown"
            }()
            entries.append(.text("Account: \(emailText)", .secondary))

            // Plan: show only Claude plan when in Claude mode; otherwise Codex plan.
            if preferClaude {
                if let plan = planFromClaude, !plan.isEmpty {
                    entries.append(.text("Plan: \(plan)", .secondary))
                }
            } else if let plan = account.plan, !plan.isEmpty {
                entries.append(.text("Plan: \(plan)", .secondary))
            }

            if let version = versionNumber(for: providerForMeta) {
                let cliName = store.metadata(for: providerForMeta).cliName
                entries.append(.text("\(cliName) \(version)", .secondary))
            }
            return Section(entries: entries)
        }

        func actionsSection() -> Section {
            Section(entries: [
                .action("Refresh now", .refresh),
                .action("Usage Dashboard", .dashboard),
            ])
        }

        func metaSection() -> Section {
            Section(entries: [
                .action("Settings...", .settings),
                .action("About CodexBar", .about),
                .action("Quit", .quit),
            ])
        }

        switch provider {
        case .codex?:
            sections.append(usageSection(for: .codex, titlePrefix: "Codex"))
            sections.append(accountSection(preferred: nil, preferClaude: false))
        case .claude?:
            let snap = store.snapshot(for: .claude)
            sections.append(usageSection(for: .claude, titlePrefix: "Claude"))
            sections.append(accountSection(preferred: snap, preferClaude: true))
        case nil:
            var addedUsage = false
            if store.isEnabled(.codex) {
                sections.append(usageSection(for: .codex, titlePrefix: "Codex"))
                addedUsage = true
            }
            if store.isEnabled(.claude) {
                sections.append(usageSection(for: .claude, titlePrefix: "Claude"))
                addedUsage = true
            }
            if addedUsage {
                sections.append(accountSection(
                    preferred: store.snapshot(for: .claude),
                    preferClaude: store.isEnabled(.claude)))
            } else {
                sections.append(Section(entries: [.text("No usage configured.", .secondary)]))
            }
        }

        sections.append(actionsSection())
        sections.append(metaSection())

        return MenuDescriptor(sections: sections)
    }
}
