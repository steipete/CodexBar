import CodexBarCore
import Foundation
import SwiftUI

struct OpenAIAPIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .openai

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.providerConfig(for: self.id)?.pluginSettings?["OPENAI_LIVE_MINUTES"]
        _ = settings[
            providerConfig: .openai,
            field: .apiKey,
        ]
        _ = settings[
            providerConfig: .openai,
            field: .secretWorkspace(logField: "projectID"),
        ]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if OpenAIAPISettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return !context.settings[
            providerConfig: .openai,
            field: .apiKey,
        ]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func appendActionMenuEntries(
        context: ProviderMenuActionContext,
        entries: inout [ProviderMenuEntry])
    {
        entries.append(contentsOf: self.liveUsageMenuEntries(
            settings: context.settings,
            environment: ProcessInfo.processInfo.environment))
    }

    @MainActor
    func liveUsageMenuEntries(
        settings: SettingsStore,
        environment: [String: String]) -> [ProviderMenuEntry]
    {
        // Resolve like refreshes do, so a selected token account counts as a credential.
        let resolved = ProviderRegistry.makeEnvironment(
            base: environment,
            provider: self.id,
            settings: settings,
            tokenOverride: nil)
        guard OpenAILiveUsageFetcher.hasCredential(environment: resolved) else { return [] }
        return [.action(L("Live Usage"), .openOpenAILiveUsage)]
    }

    @MainActor
    func throughputPresentation(
        snapshot: ProviderThroughputSnapshot,
        settings: SettingsStore,
        limitScope: ProviderModelRateLimitScope?)
        -> ProviderThroughputPresentation?
    {
        Self.throughputPresentation(
            snapshot: snapshot,
            manual: limitScope.flatMap { settings.providerConfig(for: self.id)?.modelRateLimits(for: $0) } ?? [])
    }

    static func throughputPresentation(
        snapshot: ProviderThroughputSnapshot,
        manual: [ProviderModelRateLimit])
        -> ProviderThroughputPresentation
    {
        var result = ProviderThroughputPresentation(action: .openOpenAILiveUsage)
        // Project-scoped usage is only a slice of the org-wide traffic that org limits apply to. Use the
        // snapshot's own scope: a cached snapshot can outlive a project setting change.
        guard snapshot.projectID == nil else { return result }
        let resolver = OpenAIOrgLimitResolver(manual: manual, projectCaps: nil)
        var keys: [String] = []
        var groups: [String: [ProviderThroughputSnapshot.Model]] = [:]
        for model in snapshot.models {
            guard let key = resolver.manualLimitKey(for: model.name) else { continue }
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(model)
        }
        var highestPercent: Double?
        for key in keys {
            guard let models = groups[key], let first = models.first,
                  let limit = resolver.resolve(first.name) else { continue }
            let series = models.compactMap(\.limitCountedTokensByMinute)
            let peak: Int = if series.count == models.count, series.allSatisfy({ $0.count == snapshot.minutes.count }) {
                snapshot.minutes.indices.filter { !snapshot.minutes[$0].isPending }.map { index in
                    series.reduce(0) { $0 + $1[index] }
                }.max() ?? 0
            } else {
                // Older caches lack aligned series, so retain their per-model peak behavior.
                models.map(\.peakLimitCountedTokens).max() ?? 0
            }
            let percent = Double(peak) / Double(limit.tokensPerMinute) * 100
            // Keep the earlier group in snapshot order when utilization ties.
            guard highestPercent.map({ percent > $0 }) ?? true else { continue }
            highestPercent = percent
            result.limitPercent = percent
            result.limitLine = L(
                "%@ · peak %@ · %@ of org limit",
                models.count > 1 ? key : first.name,
                ProviderThroughputSection.count(peak),
                percent.formatted(.number.precision(.fractionLength(0))) + "%")
        }
        return result
    }

    @MainActor
    func settingsToggles(context: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor] {
        [.init(
            id: "openai-live-minutes",
            title: "Tokens per minute",
            subtitle: "Fetches 1-minute usage each refresh for the menu card chart and the menu bar Tokens/min token.",
            binding: Binding(
                get: { context.settings.providerConfig(for: self.id)?.pluginSettings?["OPENAI_LIVE_MINUTES"] != "0" },
                set: { enabled in
                    context.settings.updateProviderConfig(provider: self.id) { config in
                        var values = config.pluginSettings ?? [:]
                        values["OPENAI_LIVE_MINUTES"] = enabled ? "60" : "0"
                        config.pluginSettings = values
                    }
                }),
            statusText: nil,
            actions: [],
            isVisible: nil,
            isEnabled: nil,
            onChange: nil,
            onAppDidBecomeActive: nil,
            onAppearWhenEnabled: nil)]
    }

    @MainActor
    func settingsModelLimits(context: ProviderSettingsContext) -> [ProviderSettingsModelLimitsDescriptor] {
        let scope = context.settings.modelRateLimitScope(for: self.id)
        let scopeText: String? = if context.settings.tokenAccounts(for: self.id).isEmpty {
            nil
        } else if let account = context.settings.effectiveSelectedTokenAccount(for: self.id) {
            L("Applies to the selected token account “%@”. Each account keeps its own limits.", account.label)
        } else {
            L("Applies to the OpenAI API key, not to token accounts.")
        }
        return [.init(
            id: "openai-org-limits",
            title: "Organization rate limits",
            subtitle: "OpenAI's API doesn't expose organization rate limits. Copy them from your organization's " +
                "Limits page. Model IDs match dated snapshots (gpt-5 covers gpt-5-2025-…).",
            binding: context.modelRateLimitsBinding(scope: scope),
            actions: [.openURL(
                id: "openai-open-limits",
                title: "Open organization Limits",
                url: URL(string: "https://platform.openai.com/settings/organization/limits"))],
            scopeText: scopeText,
            scope: scope)]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "openai-api-key",
                title: "Admin API key",
                subtitle: "Stored in ~/.codexbar/config.json. OPENAI_ADMIN_KEY is required for organization usage; " +
                    "legacy/user keys only get a best-effort balance fallback.",
                kind: .secure,
                placeholder: "sk-admin-...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "openai-open-billing",
                        title: "Open billing",
                        url: URL(string: "https://platform.openai.com/settings/organization/billing/overview")),
                ],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "openai-project-id",
                title: "Project ID",
                subtitle: "Optional. Applies to the configured Admin API key; selected token accounts do not " +
                    "inherit OPENAI_PROJECT_ID.",
                kind: .plain,
                placeholder: "proj_...",
                binding: context.providerConfigBinding(.secretWorkspace(logField: "projectID")),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "openai-open-projects",
                        title: "Open projects",
                        url: URL(string: "https://platform.openai.com/settings/organization/projects")),
                ],
                isVisible: nil),
        ]
    }
}
