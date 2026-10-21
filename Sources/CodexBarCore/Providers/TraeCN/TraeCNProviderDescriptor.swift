import Foundation

public enum TraeCNProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .traecn,
            settingsSection: .init(TraeCNProviderSettingsKey.self, cookieSettings: TraeCNProviderSettings.self),
            metadata: ProviderMetadata(
                id: .traecn,
                displayName: "Trae CN",
                shortDisplayName: "Trae CN",
                sessionLabel: "Credits",
                weeklyLabel: "Window",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Trae CN plan credits usage.",
                toggleTitle: "Show Trae CN plan credits",
                cliName: "traecn",
                defaultEnabled: false,
                widgetSelectable: false,
                burnDownWidgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Trae CN debug log not yet implemented",
                usesDetailBackedWindow: true,
                browserCookieOrder: nil,
                dashboardURL: "https://www.trae.cn/dashboard#usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .traecn),
                iconResourceName: "ProviderIcon-traecn",
                color: ProviderColor(red: 77 / 255, green: 124 / 255, blue: 254 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x1F2937),
                    ProviderColor(hex: 0x6B7280),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Trae CN cost summary is not supported." }),
            pace: .calendarMonthResetWindow,
            presentation: ProviderUsagePresentation(
                identityPresenter: { provider, snapshot in
                    let remaining = snapshot.detailRow(label: "Remaining")?.value
                    guard let plan = snapshot.loginMethod(for: provider), !plan.isEmpty else {
                        return ProviderIdentityPresentation(badge: remaining, plan: nil)
                    }
                    let display = UsageFormatter.cleanPlanName(plan)
                    return ProviderIdentityPresentation(badge: remaining ?? display, plan: display)
                },
                menuCard: ProviderMenuCardPresentation(
                    showsPrimaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true),
                menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true }),
                planRow: ProviderPlanRowPresentation(stripsBalancePrefix: false)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [TraeCNWebFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "traecn",
                aliases: ["trae-cn"],
                versionDetector: nil,
                browserSupportExemption: { _, _, _ in false }))
    }
}

struct TraeCNWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "traecn.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveManualCookieHeader(context: context) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let manualCookie = Self.resolveManualCookieHeader(context: context) else {
            throw TraeCNSettingsError.missingCookie()
        }
        let snapshot = try await TraeCNUsageFetcher.fetchUsage(
            cookieHeader: manualCookie,
            environment: context.env)
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
    }

    private static func resolveManualCookieHeader(context: ProviderFetchContext) -> String? {
        TraeCNCookieHeader.normalizedHeader(from: context.settings?.traecn?.manualCookieHeader)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        // Manual cookie is the only strategy; there is nothing to fall back to.
        false
    }
}
