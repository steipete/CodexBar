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
        let enabledProviders = Set(config.enabledProviders().compactMap(\.firstPartyProvider))
        var sortKeys: [String: Int] = [:]
        for (index, provider) in config.orderedProviders().enumerated() where sortKeys[provider.rawValue] == nil {
            sortKeys[provider.rawValue] = index * 10
        }

        var attachedClaudeSwap = false
        let providers = usagePayloads.enumerated().map { index, payload in
            var rowClaudeSwap: DashboardClaudeSwapInput?
            // Provider-specific by design: claude-swap account data belongs only on the first Claude row.
            if !attachedClaudeSwap, UsageProvider(rawValue: payload.provider) == .claude {
                rowClaudeSwap = claudeSwap
                attachedClaudeSwap = true
            }
            return self.makeProvider(
                payload: payload,
                cost: costByProvider[payload.provider],
                enabledProviders: enabledProviders,
                sortKey: sortKeys[payload.provider] ?? (10000 + index),
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

    // swiftlint:disable:next function_parameter_count
    private static func makeProvider(
        payload: ProviderPayload,
        cost: CostPayload?,
        enabledProviders: Set<UsageProvider>,
        sortKey: Int,
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
            id: payload.provider,
            name: metadata?.displayName ?? payload.provider,
            enabled: provider.map { enabledProviders.contains($0) } ?? true,
            source: self.dashboardSource(from: payload.source),
            status: self.makeStatus(payload.status),
            identity: self.makeIdentity(provider: provider, usage: payload.usage, mode: identityMode),
            windows: self.makeWindows(provider: provider, metadata: metadata, usage: payload.usage),
            credits: self.makeCredits(payload.credits),
            cost: self.makeCost(cost, referenceDate: generatedAt),
            display: DashboardDisplayPayload(
                accentColor: self.hexColor(descriptor?.branding.color),
                sortKey: sortKey,
                priority: "normal"),
            error: error,
            updatedAt: self.updatedAt(
                payload: payload,
                cost: cost,
                error: error,
                generatedAt: generatedAt),
            accounts: accounts,
            accountsError: claudeSwap?.adapterError)
    }

    private static func makeClaudeSwapAccount(
        _ account: ProviderAccountUsageSnapshot,
        identityMode: DashboardIdentityMode,
        weeklyWorkDays: Int?,
        generatedAt: Date) -> DashboardAccountPayload
    {
        let email = account.snapshot?.identity?.accountEmail
        let redactedEmail = identityMode != .none && email?.contains("@") == true
            ? self.dashboardEmail(email, mode: identityMode)
            : nil
        let identity = redactedEmail.map { DashboardIdentityPayload(accountEmail: $0, plan: nil) }
        // Provider-specific by design: claude-swap account windows and pace use Claude's presentation semantics.
        let metadata = ProviderDescriptorRegistry.descriptor(for: UsageProvider.claude).metadata
        return DashboardAccountPayload(
            id: "\(account.id.source):\(account.id.opaqueID)",
            label: "Account \(account.id.opaqueID)",
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

    private static func makeWindow(kind: String, label: String, window: RateWindow) -> DashboardWindowPayload {
        let used = self.clampedPercent(window.usedPercent)
        let remaining = self.clampedPercent(100 - used)
        return DashboardWindowPayload(
            kind: kind,
            label: label,
            usedPercent: used,
            remainingPercent: remaining,
            resetAt: window.resetsAt)
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
