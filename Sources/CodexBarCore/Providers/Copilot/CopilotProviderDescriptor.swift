import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum CopilotProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .copilot,
            metadata: ProviderMetadata(
                id: .copilot,
                displayName: "Copilot",
                sessionLabel: "Premium",
                weeklyLabel: "Chat",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Copilot usage",
                cliName: "copilot",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.copilotCookieImportOrder,
                dashboardURL: "https://github.com/settings/copilot",
                statusPageURL: "https://www.githubstatus.com/"),
            branding: ProviderBranding(
                iconStyle: .copilot,
                iconResourceName: "ProviderIcon-copilot",
                color: ProviderColor(red: 168 / 255, green: 85 / 255, blue: 247 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Copilot cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [CopilotAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "copilot",
                versionDetector: nil))
    }
}

struct CopilotAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "copilot.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(context: context) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let token = Self.resolveToken(context: context), !token.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        let fetcher = CopilotUsageFetcher(
            token: token,
            enterpriseHost: context.settings?.copilot?.enterpriseHost)
        let usage = try await fetcher.fetch()
        let snap = await self.addBudgetWindowsIfNeeded(to: usage, context: context)
        return self.makeResult(
            usage: snap,
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(context: ProviderFetchContext) -> String? {
        ProviderTokenResolver.copilotToken(environment: context.env)
            ?? ProviderTokenResolver.copilotResolution(environment: [
                "COPILOT_API_TOKEN": context.settings?.copilot?.apiToken ?? "",
            ])?.token
    }

    private func addBudgetWindowsIfNeeded(
        to usage: UsageSnapshot,
        context: ProviderFetchContext) async -> UsageSnapshot
    {
        guard let settings = context.settings?.copilot,
              settings.budgetExtrasEnabled,
              settings.budgetCookieSource != .off
        else { return usage }

        let manualCookieHeader = Self.budgetCookieHeaderOverride(from: settings)
        if settings.budgetCookieSource == .manual, manualCookieHeader == nil {
            return usage
        }
        do {
            let extraRateWindows = try await CopilotBudgetWebFetcher(
                cookieHeaderOverride: manualCookieHeader,
                browserDetection: context.browserDetection)
                .fetchBudgetWindows()
            guard !extraRateWindows.isEmpty else { return usage }
            return usage.with(extraRateWindows: extraRateWindows)
        } catch {
            CodexBarLog.logger(LogCategories.providers).warning(
                "Copilot budget extras unavailable",
                metadata: ["error": "\(error.localizedDescription)"])
            return usage
        }
    }

    static func budgetCookieHeaderOverride(
        from settings: ProviderSettingsSnapshot.CopilotProviderSettings) -> String?
    {
        guard settings.budgetCookieSource == .manual else { return nil }
        let cookieHeader = settings.manualBudgetCookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cookieHeader.isEmpty ? nil : cookieHeader
    }
}
