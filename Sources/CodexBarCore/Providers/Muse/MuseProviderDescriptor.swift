import Foundation

public enum MuseProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    /// OAuth-only login diagnostics. There is no API-key override: usage is minted
    /// with the Muse CLI's device-code `dca:` token. Detection is prompt-free
    /// (auth file read plus `KeychainNoUIQuery`-gated Keychain lookup).
    private static let credentials = ProviderCredentialAdapter(
        requiresAPIKeyForAPISource: false,
        authDetector: { environment, _ in
            MuseCredentials.hasLogin(environment: environment) ? ["oauth"] : []
        },
        missingCredentialMessage: { _ in
            "Muse Code login not found. Run `muse login`, then refresh CodexBar."
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .muse,
            settingsSection: .init(
                MuseProviderSettingsKey.self,
                cookieSettings: { settings in
                    .init(cookieSource: settings.cookieSource, manualCookieHeader: settings.manualCookieHeader)
                },
                credentialSettings: { context in
                    // Browser sessions are opt-in for Muse: without an explicit source or pasted header, stay Off.
                    let header = context.config?.sanitizedCookieHeader
                    return MuseProviderSettings(
                        cookieSource: context.config?.cookieSource ?? (header == nil ? .off : .manual),
                        manualCookieHeader: header,
                        webTeamID: context.config?.sanitizedWorkspaceID)
                }),
            credentials: self.credentials,
            // `workspaceID` holds the user-selected dev.meta.ai team for the browser-team quota.
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 8),
            metadata: ProviderMetadata(
                id: .muse,
                displayName: "Muse Code",
                sessionLabel: "5 hours",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Muse Code subscription 5-hour and weekly windows.",
                toggleTitle: "Show Muse Code usage",
                cliName: "muse",
                defaultEnabled: false,
                widgetSelectable: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://dev.meta.ai",
                subscriptionDashboardURL: "https://dev.meta.ai",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .muse),
                iconResourceName: "ProviderIcon-muse",
                color: ProviderColor(red: 6 / 255, green: 104 / 255, blue: 225 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x0668E1),
                    ProviderColor(hex: 0x8B5CF6),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No readable Muse session token history found." },
                menuHintLines: [.literal("Local token history · dollar costs unavailable")],
                supportsTokenSnapshot: true,
                showsHintInProviderDetails: true,
                estimateDisclaimer: "Local token history · dollar costs unavailable",
                presentation: .tokensOnly),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(supportsInlineTokenCostDashboard: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .oauth],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [MuseOAuthFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "muse",
                aliases: ["muse-code"],
                versionDetector: nil,
                supportsCostCommand: true))
    }
}

struct MuseOAuthFetchStrategy: ProviderFetchStrategy {
    let id: String = "muse.oauth"
    let kind: ProviderFetchKind = .oauth

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        MuseCredentials.hasLogin(environment: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let token = try MuseCredentials.accessToken(environment: context.env)
        // The key request (15 s) and the bounded dev.meta.ai fallback (5 × 8 s) fit one 60 s deadline.
        let runtime = try ProviderPluginRuntime(bundledPlugin: "muse", timeout: 60)
        let cookies = ProviderPluginCookieBroker(
            provider: .muse, domains: runtime.manifest.cookieDomains, context: context)
        // Reading the browser session is opt-in: an unconfigured Muse provider keeps its CLI-token-only behavior.
        let settings = context.settings?[MuseProviderSettingsKey.self]
        let cookieSource = settings?.cookieSource ?? .off
        let result = try await runtime.fetchResult(
            settings: settings?.webTeamID.map { ["MUSE_WEB_TEAM_ID": $0] } ?? [:],
            secrets: ["MUSE_DEVICE_TOKEN": token],
            sourceMode: context.sourceMode,
            cookieSource: cookieSource,
            cookieInvalidator: { cookies.rejectCookie(domain: $0) },
            cookieSessionResolver: { try cookies.nextSession(domain: $0, cachedOnly: $1) },
            cookieSessionInvalidator: { cookies.rejectCookie(domain: $0, id: $1) },
            cookieResolver: { _, domain in try cookies.cookieHeader(domain: domain) })
        return self.makeResult(usage: result.usage, sourceLabel: result.sourceLabel ?? "oauth")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
