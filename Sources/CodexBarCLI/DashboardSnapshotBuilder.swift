import CodexBarCore
import Foundation

struct DashboardClaudeSwapInput {
    let accounts: [ProviderAccountUsageSnapshot]?
    let adapterError: String?
    let weeklyWorkDays: Int?
}

/// Projects the CLI's provider usage and cost payloads into the stable,
/// display-oriented `/dashboard/v1/snapshot` contract.
enum DashboardSnapshotBuilder {
    private struct ProviderPresentation {
        let id: String
        let name: String
        let enabled: Bool
        let display: DashboardDisplayPayload
    }

    // swiftlint:disable:next function_parameter_count
    static func makeSnapshot(
        usagePayloads: [ProviderPayload],
        costPayloads: [CostPayload],
        config: CodexBarConfig,
        identityMode: DashboardIdentityMode,
        generatedAt: Date,
        refreshInterval: TimeInterval,
        codexBarVersion: String?,
        claudeSwap: DashboardClaudeSwapInput? = nil) -> DashboardSnapshotPayload
    {
        var costByProvider: [String: CostPayload] = [:]
        for cost in costPayloads {
            costByProvider[cost.provider] = cost
        }
        var attachedClaudeSwap = false
        let providers = usagePayloads.enumerated().map { index, payload in
            var rowClaudeSwap: DashboardClaudeSwapInput?
            // Provider-specific by design: claude-swap account data belongs only on the first Claude row.
            if !attachedClaudeSwap, UsageProvider(rawValue: payload.provider) == .claude {
                rowClaudeSwap = claudeSwap
                attachedClaudeSwap = true
            }
            let presentation = self.providerPresentation(
                id: payload.provider,
                config: config,
                fallbackSortKey: 10000 + index)
            return self.makeProvider(
                payload: payload,
                cost: costByProvider[payload.provider],
                presentation: presentation,
                identityMode: identityMode,
                generatedAt: generatedAt,
                claudeSwap: rowClaudeSwap)
        }

        let refreshSeconds = self.dashboardRefreshSeconds(refreshInterval)
        return DashboardSnapshotPayload(
            schemaVersion: 1,
            generatedAt: generatedAt,
            staleAfterSeconds: max(180, refreshSeconds * 3),
            host: DashboardHostPayload(
                codexBarVersion: codexBarVersion,
                refreshIntervalSeconds: refreshSeconds),
            providers: providers)
    }

    static func makeShellSnapshot(
        config: CodexBarConfig,
        providers requestedProviders: [UsageProvider]? = nil,
        generatedAt: Date,
        refreshInterval: TimeInterval,
        codexBarVersion: String?) -> DashboardSnapshotPayload
    {
        let providers = requestedProviders
            ?? config.enabledProviders().compactMap(\.firstPartyProvider)
        let rows = providers.enumerated().map { index, provider in
            let presentation = self.providerPresentation(
                id: provider.rawValue,
                config: config,
                fallbackSortKey: 10000 + index)
            return DashboardProviderPayload(
                id: presentation.id,
                name: presentation.name,
                enabled: presentation.enabled,
                source: "",
                status: nil,
                identity: nil,
                windows: [],
                credits: nil,
                cost: nil,
                display: presentation.display,
                error: nil,
                updatedAt: nil,
                accounts: nil,
                accountsError: nil,
                detail: .shell)
        }
        let refreshSeconds = self.dashboardRefreshSeconds(refreshInterval)
        return DashboardSnapshotPayload(
            schemaVersion: 1,
            generatedAt: generatedAt,
            staleAfterSeconds: max(180, refreshSeconds * 3),
            host: DashboardHostPayload(
                codexBarVersion: codexBarVersion,
                refreshIntervalSeconds: refreshSeconds),
            providers: rows)
    }

    // swiftlint:disable:next function_parameter_count
    private static func makeProvider(
        payload: ProviderPayload,
        cost: CostPayload?,
        presentation: ProviderPresentation,
        identityMode: DashboardIdentityMode,
        generatedAt: Date,
        claudeSwap: DashboardClaudeSwapInput?) -> DashboardProviderPayload
    {
        let provider = UsageProvider(rawValue: payload.provider)
        let descriptor = provider.map { ProviderDescriptorRegistry.descriptor(for: $0) }
        let metadata = descriptor?.metadata

        let error = payload.error ?? cost?.error
        let accounts = claudeSwap?.adapterError == nil
            ? claudeSwap?.accounts?.map { account in
                self.makeClaudeSwapAccount(
                    account,
                    identityMode: identityMode,
                    weeklyWorkDays: claudeSwap?.weeklyWorkDays,
                    generatedAt: generatedAt)
            }
            : nil
        return DashboardProviderPayload(
            id: presentation.id,
            name: presentation.name,
            enabled: presentation.enabled,
            source: self.dashboardSource(from: payload.source),
            status: self.makeStatus(payload.status),
            identity: self.makeIdentity(provider: provider, usage: payload.usage, mode: identityMode),
            windows: self.makeWindows(provider: provider, metadata: metadata, usage: payload.usage),
            credits: self.makeCredits(payload.credits),
            cost: self.makeCost(cost, referenceDate: generatedAt),
            display: presentation.display,
            error: error,
            updatedAt: self.updatedAt(
                payload: payload,
                cost: cost,
                error: error,
                generatedAt: generatedAt),
            accounts: accounts,
            accountsError: claudeSwap?.adapterError)
    }

    private static func providerPresentation(
        id: String,
        config: CodexBarConfig,
        fallbackSortKey: Int) -> ProviderPresentation
    {
        let provider = UsageProvider(rawValue: id)
        let descriptor = provider.map { ProviderDescriptorRegistry.descriptor(for: $0) }
        let enabledProviders = Set(config.enabledProviders().compactMap(\.firstPartyProvider))
        let sortKey = config.orderedProviders().firstIndex { $0.rawValue == id }.map { $0 * 10 }
            ?? fallbackSortKey
        let accentOverride = ProviderInstanceID(rawValue: id)
            .flatMap { config.providerConfig(for: $0)?.accentColor }
            .flatMap { ProviderColor(hexString: $0) }
        return ProviderPresentation(
            id: id,
            name: descriptor?.metadata.displayName ?? id,
            enabled: provider.map { enabledProviders.contains($0) } ?? true,
            display: DashboardDisplayPayload(
                accentColor: self.hexColor(accentOverride ?? descriptor?.branding.color),
                sortKey: sortKey,
                priority: "normal"))
    }

    private static func makeClaudeSwapAccount(
        _ account: ProviderAccountUsageSnapshot,
        identityMode: DashboardIdentityMode,
        weeklyWorkDays: Int?,
        generatedAt: Date) -> DashboardAccountPayload
    {
        // Provider-specific by design: identity stays the source email; the card label may be an alias
        // or an "email · org" disambiguation, and redaction rewrites only the email prefix.
        let sourceEmail: String? = {
            if let email = account.accountEmail, email.contains("@") { return email }
            if let email = account.snapshot?.identity?.accountEmail, email.contains("@") { return email }
            return nil
        }()
        let presentedEmail = identityMode != .none && sourceEmail?.contains("@") == true
            ? self.dashboardEmail(sourceEmail, mode: identityMode)
            : nil
        let identity = presentedEmail.map { DashboardIdentityPayload(accountEmail: $0, plan: nil) }
        let trimmedLabel = account.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackLabel = trimmedLabel.isEmpty ? "Account \(account.id.opaqueID)" : trimmedLabel
        let label = self.claudeSwapDashboardLabel(
            displayLabel: fallbackLabel,
            sourceEmail: sourceEmail,
            presentedEmail: presentedEmail,
            accountID: account.id.opaqueID,
            identityMode: identityMode)
        // Provider-specific by design: claude-swap account windows and pace use Claude's presentation semantics.
        let metadata = ProviderDescriptorRegistry.descriptor(for: UsageProvider.claude).metadata
        return DashboardAccountPayload(
            id: "\(account.id.source):\(account.id.opaqueID)",
            label: label,
            active: account.isActive,
            identity: identity,
            windows: self.makeWindows(provider: .claude, metadata: metadata, usage: account.snapshot),
            pace: account.snapshot.flatMap {
                CLIRenderer.providerPacePayload(
                    provider: .claude,
                    snapshot: $0,
                    weeklyWorkDays: weeklyWorkDays,
                    now: generatedAt)
            },
            error: account.error,
            updatedAt: account.snapshot?.updatedAt)
    }

    private static func claudeSwapDashboardLabel(
        displayLabel: String,
        sourceEmail: String?,
        presentedEmail: String?,
        accountID: String,
        identityMode: DashboardIdentityMode) -> String
    {
        if let presentedEmail {
            if let sourceEmail,
               displayLabel.contains("@"),
               displayLabel == sourceEmail || displayLabel.hasPrefix(sourceEmail)
            {
                let suffix = String(displayLabel.dropFirst(sourceEmail.count))
                return presentedEmail + self.redactEmailShapedText(suffix, mode: identityMode)
            }
            return self.redactEmailShapedText(displayLabel, mode: identityMode)
        }
        return displayLabel.contains("@") ? "Account \(accountID)" : displayLabel
    }

    private static func dashboardSource(from source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private static func makeStatus(_ status: ProviderStatusPayload?) -> DashboardStatusPayload? {
        guard let status else { return nil }
        return DashboardStatusPayload(
            level: self.dashboardStatusLevel(status.indicator),
            label: status.indicator.label,
            updatedAt: status.updatedAt)
    }

    private static func dashboardStatusLevel(_ indicator: ProviderStatusPayload.ProviderStatusIndicator) -> String {
        switch indicator {
        case .none:
            "ok"
        case .minor, .maintenance:
            "warning"
        case .major, .critical:
            "critical"
        case .unknown:
            "unknown"
        }
    }

    private static func makeIdentity(
        provider: UsageProvider?,
        usage: UsageSnapshot?,
        mode: DashboardIdentityMode) -> DashboardIdentityPayload?
    {
        guard mode != .none,
              let provider,
              let identity = usage?.identity(for: provider.instanceID)
        else {
            return nil
        }

        let email = self.dashboardEmail(identity.accountEmail, mode: mode)
        let plan = self.dashboardPlan(identity.loginMethod, provider: provider)
        guard email != nil || plan != nil else { return nil }
        return DashboardIdentityPayload(accountEmail: email, plan: plan)
    }

    private static func dashboardEmail(_ email: String?, mode: DashboardIdentityMode) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty
        else {
            return nil
        }
        guard mode == .redacted else { return email }
        guard let at = email.lastIndex(of: "@") else { return "redacted" }
        return "redacted\(email[at...])"
    }

    /// Redacts every bounded `@` address range, including apostrophes, quoted local parts,
    /// internal domains, and domain literals, so Hide Personal Info cannot leak a second address.
    private static func redactEmailShapedText(_ text: String, mode: DashboardIdentityMode) -> String {
        guard mode == .redacted else { return text }
        var output = ""
        var cursor = text.startIndex
        var search = text.startIndex
        while let at = text[search...].firstIndex(of: "@") {
            let localStart = self.emailTokenStart(in: text, before: at)
            let domainEnd = self.emailTokenEnd(in: text, after: at)
            if localStart < at, domainEnd > text.index(after: at) {
                output += text[cursor..<localStart]
                output += self.dashboardEmail(String(text[localStart..<domainEnd]), mode: .redacted) ?? "redacted"
                cursor = domainEnd
                search = domainEnd
            } else {
                search = text.index(after: at)
            }
        }
        output += text[cursor...]
        return output
    }

    private static func emailTokenStart(in text: String, before at: String.Index) -> String.Index {
        var idx = at
        var inQuotedLocalPart = false
        while idx > text.startIndex {
            let previous = text.index(before: idx)
            let character = text[previous]
            if character == "\"" {
                inQuotedLocalPart.toggle()
                idx = previous
                continue
            }
            if !inQuotedLocalPart, self.isEmailBoundary(character) { break }
            idx = previous
        }
        return idx
    }

    private static func emailTokenEnd(in text: String, after at: String.Index) -> String.Index {
        var idx = text.index(after: at)
        guard idx < text.endIndex else { return idx }
        if text[idx] == "[" {
            while idx < text.endIndex {
                let character = text[idx]
                idx = text.index(after: idx)
                if character == "]" { break }
            }
            return idx
        }
        while idx < text.endIndex, !self.isEmailBoundary(text[idx]) {
            idx = text.index(after: idx)
        }
        return idx
    }

    private static func isEmailBoundary(_ character: Character) -> Bool {
        character.isWhitespace || "()<>:,;·/".contains(character)
    }

    private static func dashboardPlan(_ raw: String?, provider: UsageProvider) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }

        // Provider-specific by design: Codex plan aliases and Kilo's auto-top-up suffix require distinct cleanup.
        if provider == .codex {
            return CodexPlanFormatting.displayName(raw) ?? UsageFormatter.cleanPlanName(raw)
        }
        if provider == .kilo {
            let firstPlanSegment = raw
                .components(separatedBy: "·")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.lowercased().hasPrefix("auto top-up:") }
            return firstPlanSegment.map(UsageFormatter.cleanPlanName)
        }
        return UsageFormatter.cleanPlanName(raw)
    }

    private static func makeWindows(
        provider: UsageProvider?,
        metadata: ProviderMetadata?,
        usage: UsageSnapshot?) -> [DashboardWindowPayload]
    {
        guard let usage else { return [] }
        // Provider-specific by design: Antigravity's primary and secondary are representatives
        // copied out of its own quota-summary lanes so the icon and menu bar have standard slots
        // to read. Emitting all three repeats two lanes under the generic session and weekly
        // labels, so the dashboard renders the summary lanes alone, one per quota bucket.
        if provider == .antigravity, let windows = self.antigravityQuotaSummaryWindows(usage) {
            return windows
        }
        let labels = self.rateWindowLabels(provider: provider, metadata: metadata, usage: usage)
        var windows: [DashboardWindowPayload] = []
        // Provider-specific by design: Amp subscription payloads model balance and orb as non-time-window kinds.
        let isAmpSubscription = provider == .amp && usage.secondary != nil

        if let primary = usage.primary {
            let kind = isAmpSubscription ? "other" : "session"
            windows.append(self.makeWindow(kind: kind, label: labels.primary, window: primary))
        }
        if let secondary = usage.secondary {
            let kind = isAmpSubscription ? "orb" : "weekly"
            windows.append(self.makeWindow(kind: kind, label: labels.secondary, window: secondary))
        }
        if let tertiary = usage.tertiary {
            windows.append(self.makeWindow(kind: "tertiary", label: labels.tertiary, window: tertiary))
        }
        for extra in usage.extraRateWindows ?? [] {
            windows.append(self.makeWindow(kind: extra.id, label: extra.title, window: extra.window))
        }

        return windows
    }

    /// Display lanes for an Antigravity quota-summary snapshot, or `nil` when the snapshot has no
    /// summary lanes and must keep the standard primary and secondary rows. Every family stays in the
    /// payload, because a script client reads the same document and must not lose a window. The lanes of
    /// a family that reports no usage carry `idle`, the same rule the menu card and the widget use to
    /// hide that family, so the web UI can drop those rows without repeating the rule in JavaScript.
    private static func antigravityQuotaSummaryWindows(_ usage: UsageSnapshot) -> [DashboardWindowPayload]? {
        let extras = usage.extraRateWindows ?? []
        guard extras.contains(where: { AntigravityStatusSnapshot.isQuotaSummaryWindowID($0.id) }) else {
            return nil
        }
        let idleWindowIDs = AntigravityQuotaFamilyVisibility.idleWindowIDs(in: usage)
        return extras.map {
            self.makeWindow(
                kind: $0.id,
                label: $0.title,
                window: $0.window,
                idle: idleWindowIDs.contains($0.id))
        }
    }

    private struct RateWindowLabels {
        let primary: String
        let secondary: String
        let tertiary: String
    }

    private static func rateWindowLabels(
        provider: UsageProvider?,
        metadata: ProviderMetadata?,
        usage: UsageSnapshot) -> RateWindowLabels
    {
        guard let provider else {
            return RateWindowLabels(
                primary: metadata?.sessionLabel ?? "Session",
                secondary: metadata?.weeklyLabel ?? "Weekly",
                tertiary: metadata?.opusLabel ?? "Tertiary")
        }
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let labels = descriptor.presentation.rateWindowLabels(metadata: descriptor.metadata, snapshot: usage)
        return RateWindowLabels(
            primary: labels.primary,
            secondary: labels.secondary,
            tertiary: labels.tertiary)
    }

    private static func makeWindow(
        kind: String,
        label: String,
        window: RateWindow,
        idle: Bool = false) -> DashboardWindowPayload
    {
        let used = self.clampedPercent(window.usedPercent)
        let remaining = self.clampedPercent(100 - used)
        return DashboardWindowPayload(
            kind: kind,
            label: label,
            usedPercent: used,
            remainingPercent: remaining,
            resetAt: window.resetsAt,
            idle: idle)
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func makeCredits(_ credits: CreditsSnapshot?) -> DashboardCreditsPayload? {
        guard let credits else { return nil }
        return DashboardCreditsPayload(remaining: credits.remaining, unit: "credits")
    }

    private static func makeCost(_ cost: CostPayload?, referenceDate: Date) -> DashboardCostPayload? {
        guard let cost else { return nil }
        let todayUSD = self.todayCostUSD(cost, referenceDate: referenceDate)
        guard todayUSD != nil || cost.last30DaysCostUSD != nil else { return nil }
        return DashboardCostPayload(
            todayUSD: todayUSD,
            last30DaysUSD: cost.last30DaysCostUSD)
    }

    private static func todayCostUSD(_ cost: CostPayload, referenceDate: Date) -> Double? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        let dayKey = String(format: "%04d-%02d-%02d", year, month, day)
        return cost.daily.first { String($0.date.prefix(10)) == dayKey }?.costUSD
    }

    private static func updatedAt(
        payload: ProviderPayload,
        cost: CostPayload?,
        error: ProviderErrorPayload?,
        generatedAt: Date) -> Date?
    {
        let newest = [payload.status?.updatedAt, payload.usage?.updatedAt, payload.credits?.updatedAt, cost?.updatedAt]
            .compactMap(\.self)
            .max()
        if let newest {
            return newest
        }
        return error == nil ? nil : generatedAt
    }

    private static func dashboardRefreshSeconds(_ refreshInterval: TimeInterval) -> Int {
        guard refreshInterval > 0 else { return 0 }
        let maximum = Int.max / 3
        guard refreshInterval < Double(maximum) else { return maximum }
        return min(maximum, Int(refreshInterval.rounded(.up)))
    }

    private static func hexColor(_ color: ProviderColor?) -> String {
        guard let color else { return "#6E6E6E" }
        let red = Int((self.clampedColor(color.red) * 255).rounded())
        let green = Int((self.clampedColor(color.green) * 255).rounded())
        let blue = Int((self.clampedColor(color.blue) * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func clampedColor(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
