import Foundation

public enum CopilotProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

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
        let snap = await self.addBudgetWindowsIfNeeded(to: usage, token: token, context: context)
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
        token: String,
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
            let expectedAccountIdentifier = try await self.expectedBudgetAccountIdentifier(
                token: token,
                settings: settings)
            let extraRateWindows = try await CopilotBudgetWebFetcher(
                cookieHeaderOverride: manualCookieHeader,
                expectedGitHubAccountIdentifier: expectedAccountIdentifier,
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
        return CookieHeaderNormalizer.normalize(settings.manualBudgetCookieHeader)
    }

    private func expectedBudgetAccountIdentifier(
        token: String,
        settings: ProviderSettingsSnapshot.CopilotProviderSettings) async throws -> String
    {
        let identity = try await CopilotUsageFetcher.fetchGitHubIdentity(token: token)
        let tokenIdentifier = CopilotBudgetWebFetcher.normalizedGitHubAccountIdentifier(for: identity)
        if let selectedIdentifier = Self.normalizedBudgetAccountIdentifier(settings.selectedAccountExternalIdentifier),
           selectedIdentifier != tokenIdentifier.lowercased(),
           selectedIdentifier != identity.login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        {
            CodexBarLog.logger(LogCategories.providers).warning(
                "Ignoring stale Copilot account identifier")
        }
        return tokenIdentifier
    }

    private static func normalizedBudgetAccountIdentifier(_ identifier: String?) -> String? {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }
}
