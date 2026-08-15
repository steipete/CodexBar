import Foundation

public enum ZaiProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: ZaiSettingsReader.apiTokenKey,
        resolve: ZaiSettingsReader.apiToken,
        tokenAccountSupport: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Stored in the CodexBar config file.",
            placeholder: "Paste token…",
            injection: .environment(key: ZaiSettingsReader.apiTokenKey),
            requiresManualCookieSource: false,
            cookieName: nil,
            showsTeamModeControls: true),
        usesRegion: true,
        configValidator: { config in
            var issues = ProviderCredentialAdapter.regionValidator(
                displayName: "z.ai",
                isValid: { ZaiAPIRegion(rawValue: $0) != nil })(config)
            if let accounts = config.tokenAccounts?.accounts,
               accounts.contains(where: {
                   $0.sanitizedUsageScope?.lowercased() == ZaiUsageScope.team.rawValue &&
                       ($0.sanitizedOrganizationID == nil || $0.sanitizedWorkspaceID == nil)
               })
            {
                issues.append(CodexBarConfigIssue(
                    severity: .warning,
                    provider: .zai,
                    field: "tokenAccounts",
                    code: "zai_team_context_missing",
                    message: "z.ai Team mode requires both organizationID and workspaceID."))
            }
            return issues
        },
        missingCredentialMessage: { _ in ZaiSettingsError.missingToken.errorDescription },
        accountEnvironmentOverride: { environment, account in
            let rawScope = account.sanitizedUsageScope?.lowercased()
            let scope = rawScope.flatMap(ZaiUsageScope.init(rawValue:)) ?? .personal
            environment.removeValue(forKey: ZaiSettingsReader.bigModelOrganizationKey)
            environment.removeValue(forKey: ZaiSettingsReader.bigModelProjectKey)
            guard scope == .team else { return }
            if let organizationID = account.sanitizedOrganizationID {
                environment[ZaiSettingsReader.bigModelOrganizationKey] = organizationID
            }
            if let projectID = account.sanitizedWorkspaceID {
                environment[ZaiSettingsReader.bigModelProjectKey] = projectID
            }
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .zai,
            settingsSection: .init(ZaiProviderSettingsKey.self, credentialSettings: { context in
                let region = context.config?.sanitizedRegion.flatMap(ZaiAPIRegion.init(rawValue:)) ?? .global
                let rawScope = context.account?.sanitizedUsageScope?.lowercased()
                let scope = rawScope.flatMap(ZaiUsageScope.init(rawValue:)) ?? .personal
                let teamContext: ZaiBigModelTeamContext? = scope == .team
                    ? ZaiBigModelTeamContext(
                        organizationID: context.account?.sanitizedOrganizationID,
                        projectID: context.account?.sanitizedWorkspaceID)
                    : nil
                return ZaiProviderSettings(apiRegion: region, usageScope: scope, teamContext: teamContext)
            }),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .zai,
                displayName: "z.ai / GLM",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show z.ai / GLM usage",
                cliName: "zai",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: ["free": "Free", "pro": "Pro", "max": "Max", "team": "Team"],
                dashboardURL: ZaiAPIRegion.global.dashboardURL.absoluteString,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .zai),
                iconResourceName: "ProviderIcon-zai",
                color: ProviderColor(red: 232 / 255, green: 90 / 255, blue: 106 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x126EF6),
                    ProviderColor(hex: 0x2D2D2D),
                    ProviderColor(hex: 0xDFE2E7),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "z.ai cost summary is not supported." },
                supportsTokenSnapshot: true),
            pace: ProviderPaceCapability(
                resetWindowPace: .custom { window, _ in
                    Self.isMonthlyMCPWindow(window)
                },
                inferredMonthlyDuration: .custom { window in
                    Self.isMonthlyMCPWindow(window)
                },
                primary: .exact(kind: .session, minutes: 5 * 60),
                secondary: .exact(kind: .weekly, minutes: 7 * 24 * 60),
                sessionPaceWindowRule: .windowDuration(minutes: 5 * 60)),
            presentation: ProviderUsagePresentation(
                extraRateWindowSelector: { snapshot in
                    (snapshot.extraRateWindows ?? []).filter { $0.id == "zai-mcp" }
                },
                automaticSelectionPrioritizesExhaustedWindow: false,
                menuBarWindowResolver: { context in
                    guard context.metric == .automatic else { return .unhandled }
                    return .resolved(ProviderUsagePresentation.mostConstrained(
                        context.snapshot.primary,
                        context.snapshot.secondary))
                },
                primaryBindingQuotaLanes: [.secondary]),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "zai",
                aliases: ["z.ai"],
                versionDetector: nil,
                supportsCostCommand: true))
    }

    private static func isMonthlyMCPWindow(_ window: RateWindow) -> Bool {
        window.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes
            && window.resetDescription == "MCP"
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "zai.js",
                    provider: .zai,
                    bundledPlugin: "zai",
                    secretKey: ZaiSettingsReader.apiTokenKey,
                    sourceLabel: "api",
                    validateContext: { context in
                        let settings = context.settings?.zai
                        let region = settings?.apiRegion ?? .global
                        try ZaiSettingsReader.validateEndpointOverrides(region: region, environment: context.env)
                        let scope = settings?.usageScope ?? .personal
                        if scope == .team,
                           settings?.teamContext == nil,
                           ZaiBigModelTeamContext(environment: context.env) == nil
                        {
                            throw ZaiProviderSettingsError.missingTeamContext
                        }
                    },
                    resolveValues: { context in
                        let settings = context.settings?.zai
                        let region = settings?.apiRegion ?? .global
                        guard let token = ZaiSettingsReader.apiToken(
                            for: region,
                            environment: context.env)
                        else { return nil }
                        let scope = settings?.usageScope ?? .personal
                        var plainValues = [
                            "Z_AI_REGION": region.rawValue,
                            "Z_AI_USAGE_SCOPE": scope.rawValue,
                            "Z_AI_QUOTA_ENDPOINT": ZaiEndpointRouter.resolveQuotaURL(
                                region: region,
                                environment: context.env).absoluteString,
                            "Z_AI_MODEL_USAGE_ENDPOINT": ZaiEndpointRouter.resolveModelUsageURL(
                                region: region,
                                environment: context.env).absoluteString,
                        ]
                        if let team = settings?.teamContext ?? ZaiBigModelTeamContext(environment: context.env) {
                            plainValues["Z_AI_ORGANIZATION"] = team.organizationID
                            plainValues["Z_AI_PROJECT"] = team.projectID
                        }
                        return ScriptFetchStrategy.Values(
                            settings: plainValues,
                            secrets: [ZaiSettingsReader.apiTokenKey: token])
                    },
                    isEnabled: { _ in true })]
            }))
    }
}
