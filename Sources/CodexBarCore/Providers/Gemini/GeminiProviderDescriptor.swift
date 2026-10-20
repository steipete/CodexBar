import Foundation

public enum GeminiProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .gemini,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(
                supported: [.automatic, .primary, .secondary, .average]),
            settingsSection: .init(GeminiProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            metadata: ProviderMetadata(
                id: .gemini,
                displayName: "Gemini",
                sessionLabel: "Pro",
                weeklyLabel: "Flash",
                opusLabel: "Flash Lite",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Gemini usage",
                cliName: "gemini",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [
                    "free": "Free", "paid": "Paid", "plus": "Plus", "workspace": "Workspace",
                    "legacy": "Legacy", "gemini code assist in google one ai pro": "Google One AI Pro",
                ],
                debugLogUnavailableMessage: "Gemini debug log not yet implemented",
                debugPane: ProviderDebugPaneCapabilities(errorSimulationOrder: 2),
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://gemini.google.com",
                changelogURL: "https://github.com/google-gemini/gemini-cli/releases",
                statusPageURL: nil,
                statusLinkURL: "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history",
                statusWorkspaceProductID: "npdyhgECDJ6tB66MxXyo"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .gemini),
                iconResourceName: "ProviderIcon-gemini",
                color: ProviderColor(red: 171 / 255, green: 135 / 255, blue: 234 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x4285F4),
                    ProviderColor(hex: 0xA142F4),
                    ProviderColor(hex: 0xD96570),
                ],
                burnDownWidgetColor: ProviderColor(red: 0.420, green: 0.440, blue: 0.900)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Gemini cost summary is not supported." }),
            presentation: ProviderUsagePresentation(
                rateWindowLabeler: { metadata, snapshot, _ in
                    let isWeb = snapshot.primary?.windowMinutes == 300 || snapshot.secondary?.windowMinutes == 10080
                    return ProviderRateWindowLabels(
                        primary: isWeb ? "5-hour" : metadata.sessionLabel,
                        secondary: isWeb ? "Weekly" : metadata.weeklyLabel,
                        tertiary: metadata.opusLabel ?? "",
                        showsTertiary: !isWeb && metadata.supportsOpus)
                },
                identityPresenter: { provider, snapshot in
                    guard let plan = snapshot.loginMethod(for: provider), !plan.isEmpty else {
                        return ProviderIdentityPresentation(badge: nil, plan: nil)
                    }
                    let display = UsageFormatter.cleanPlanName(plan)
                    return ProviderIdentityPresentation(badge: display, plan: display)
                },
                iconDecorations: [.gemini],
                menuBarWindowResolver: { context in
                    guard context.metric == .automatic else { return .unhandled }
                    let snapshot = context.snapshot
                    return .resolved(
                        ProviderUsagePresentation.exhausted(snapshot.primary, snapshot.secondary, snapshot.tertiary)
                            ?? snapshot.primary ?? snapshot.secondary ?? snapshot.tertiary)
                }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    // App quotas belong to a browser account; never silently substitute them for CLI quotas.
                    guard context.sourceMode == .web else { return [GeminiStatusFetchStrategy()] }
                    return [ScriptFetchStrategy(
                        id: "gemini.web",
                        provider: .gemini,
                        bundledPlugin: "gemini-web",
                        sourceLabel: "Gemini app",
                        kind: .web,
                        timeout: context.webTimeout,
                        resolveValues: { _ in .init() },
                        isEnabled: { _ in true })]
                })),
            cli: ProviderCLIConfig(
                name: "gemini",
                binaryLocator: { BinaryLocator.resolveGeminiBinary(env: $0) },
                versionDetector: { _ in ProviderVersionDetector.geminiVersion() },
                browserSupportExemption: { source, _, settings in
                    source == .web && settings?[GeminiProviderSettingsKey.self]?.cookieSource == .manual
                }))
    }
}

public enum GeminiProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.gemini
    public typealias Section = CookieProviderSettings
}

struct GeminiStatusFetchStrategy: ProviderFetchStrategy {
    static let sourceLabel = "oauth-api"

    let id: String = "gemini.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = GeminiStatusProbe()
        let snap = try await probe.fetch()
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: Self.sourceLabel)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
