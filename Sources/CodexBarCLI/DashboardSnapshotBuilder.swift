import CodexBarCore
import Foundation

enum DashboardSnapshotBuilder {
    // swiftlint:disable:next function_parameter_count
    static func makeSnapshot(
        usagePayloads: [ProviderPayload],
        costPayloads: [CostPayload],
        config: CodexBarConfig,
        identityMode: DashboardIdentityMode,
        generatedAt: Date,
        refreshInterval: TimeInterval,
        codexBarVersion: String?) -> DashboardSnapshotPayload
    {
        var costByProvider: [String: CostPayload] = [:]
        for cost in costPayloads {
            costByProvider[cost.provider] = cost
        }
        let enabledProviders = Set(config.enabledProviders())
        var sortKeys: [String: Int] = [:]
        for (index, provider) in config.orderedProviders().enumerated() where sortKeys[provider.rawValue] == nil {
            sortKeys[provider.rawValue] = index * 10
        }

        let providers = usagePayloads.enumerated().map { index, payload in
            self.makeProvider(
                payload: payload,
                cost: costByProvider[payload.provider],
                enabledProviders: enabledProviders,
                sortKey: sortKeys[payload.provider] ?? (10000 + index),
                identityMode: identityMode,
                generatedAt: generatedAt)
        }

        return DashboardSnapshotPayload(
            schemaVersion: 1,
            generatedAt: generatedAt,
            staleAfterSeconds: max(180, Int(refreshInterval.rounded(.up)) * 3),
            host: DashboardHostPayload(
                codexBarVersion: codexBarVersion,
                refreshIntervalSeconds: max(0, Int(refreshInterval.rounded()))),
            providers: providers)
    }

    // swiftlint:disable:next function_parameter_count
    private static func makeProvider(
        payload: ProviderPayload,
        cost: CostPayload?,
        enabledProviders: Set<UsageProvider>,
        sortKey: Int,
        identityMode: DashboardIdentityMode,
        generatedAt: Date) -> DashboardProviderPayload
    {
        let provider = UsageProvider(rawValue: payload.provider)
        let descriptor = provider.map { ProviderDescriptorRegistry.descriptor(for: $0) }
        let metadata = descriptor?.metadata

        return DashboardProviderPayload(
            id: payload.provider,
            name: metadata?.displayName ?? payload.provider,
            enabled: provider.map { enabledProviders.contains($0) } ?? true,
            source: self.dashboardSource(from: payload.source),
            status: self.makeStatus(payload.status),
            identity: self.makeIdentity(provider: provider, usage: payload.usage, mode: identityMode),
            windows: self.makeWindows(provider: provider, metadata: metadata, usage: payload.usage),
            credits: self.makeCredits(payload.credits),
            cost: self.makeCost(cost),
            display: DashboardDisplayPayload(
                accentColor: self.hexColor(descriptor?.branding.color),
                sortKey: sortKey,
                priority: "normal"),
            error: payload.error,
            updatedAt: self.updatedAt(
                usage: payload.usage,
                credits: payload.credits,
                cost: cost,
                error: payload.error,
                generatedAt: generatedAt))
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
              let identity = usage?.identity(for: provider)
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
        guard let at = email.firstIndex(of: "@") else { return "redacted" }
        return "redacted\(email[at...])"
    }

    private static func dashboardPlan(_ raw: String?, provider: UsageProvider) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }

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

        if let primary = usage.primary {
            windows.append(self.makeWindow(kind: "session", label: labels.primary, window: primary))
        }
        if let secondary = usage.secondary {
            windows.append(self.makeWindow(kind: "weekly", label: labels.secondary, window: secondary))
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
        if provider == .factory, usage.tertiary != nil {
            return RateWindowLabels(primary: "5-hour", secondary: "Weekly", tertiary: "Monthly")
        }

        return RateWindowLabels(
            primary: metadata?.sessionLabel ?? "Session",
            secondary: metadata?.weeklyLabel ?? "Weekly",
            tertiary: metadata?.opusLabel ?? "Tertiary")
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

    private static func makeCost(_ cost: CostPayload?) -> DashboardCostPayload? {
        guard let cost else { return nil }
        guard cost.sessionCostUSD != nil || cost.last30DaysCostUSD != nil else { return nil }
        return DashboardCostPayload(
            todayUSD: cost.sessionCostUSD,
            last30DaysUSD: cost.last30DaysCostUSD)
    }

    private static func updatedAt(
        usage: UsageSnapshot?,
        credits: CreditsSnapshot?,
        cost: CostPayload?,
        error: ProviderErrorPayload?,
        generatedAt: Date) -> Date?
    {
        if let usage { return usage.updatedAt }
        if let credits { return credits.updatedAt }
        if let cost { return cost.updatedAt }
        return error == nil ? nil : generatedAt
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
