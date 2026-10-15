import Foundation

public enum AugmentProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Session tokens",
        subtitle: "Store multiple Augment Cookie headers.",
        placeholder: "Cookie: …",
        injection: .cookieHeader,
        requiresManualCookieSource: true,
        cookieName: nil))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .augment,
            settingsSection: .init(AugmentProviderSettingsKey.self, cookieSettings: AugmentProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .augment,
                displayName: "Augment",
                sessionLabel: "Credits",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Augment Code credits for AI-powered coding assistance.",
                toggleTitle: "Show Augment usage",
                cliName: "augment",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [
                    "free": "Free", "community": "Community", "indie": "Indie", "pro": "Pro",
                    "team": "Team", "enterprise": "Enterprise",
                ],
                debugPane: ProviderDebugPaneCapabilities(probeLogOrder: 3, errorSimulationOrder: 4),
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://app.augmentcode.com/account/subscription",
                statusPageURL: "https://status.augmentcode.com"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .augment),
                iconResourceName: "ProviderIcon-augment",
                color: ProviderColor(hex: 0x1AA049),
                confettiPalette: [
                    ProviderColor(hex: 0x1AA049),
                    ProviderColor(hex: 0x111111),
                    ProviderColor(hex: 0xFFF7ED),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Augment cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    var strategies: [any ProviderFetchStrategy] = []
                    // Try CLI first (no browser prompts!)
                    strategies.append(AugmentCLIFetchStrategy())
                    // Fallback to web (browser cookies)
                    strategies.append(AugmentStatusFetchStrategy())
                    return strategies
                })),
            cli: ProviderCLIConfig(
                name: "augment",
                versionDetector: nil))
    }
}

struct AugmentCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "augment.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Check if auggie CLI is installed
        let env = ProcessInfo.processInfo.environment
        let loginPATH = LoginShellPathCache.shared.current
        return BinaryLocator.resolveAuggieBinary(env: env, loginPATH: loginPATH) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = AuggieCLIProbe()
        let snap = try await probe.fetch()
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "cli")
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        // Fallback to web if CLI fails (not authenticated, etc.)
        if let cliError = error as? AuggieCLIError {
            switch cliError {
            case .notAuthenticated, .noOutput, .parseError:
                return true
            }
        }
        return true
    }
}

struct AugmentStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "augment.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.augment?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = AugmentStatusProbe()
        let manual = Self.manualCookieHeader(from: context)
        let logger: ((String) -> Void)? = context.verbose
            ? { msg in CodexBarLog.logger(LogCategories.provider(.augment)).verbose(msg) }
            : nil
        let snap = try await probe.fetch(cookieHeaderOverride: manual, logger: logger)
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.augment?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.augment?.manualCookieHeader)
    }
}
