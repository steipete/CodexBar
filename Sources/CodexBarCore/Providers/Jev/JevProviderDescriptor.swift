import Foundation

public enum JevProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .jev,
            settingsSection: .init(JevProviderSettingsKey.self, cookieSettings: JevProviderSettings.self),
            metadata: ProviderMetadata(
                id: .jev,
                displayName: "Jev",
                sessionLabel: "Usage",
                weeklyLabel: "Last 7 days",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Jev usage",
                cliName: "jev",
                defaultEnabled: false,
                widgetSelectable: true,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://console.typesafe.ai/usage",
                subscriptionDashboardURL: "https://console.typesafe.ai/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .jev),
                iconResourceName: "ProviderIcon-jev",
                color: ProviderColor(hex: 0x111111),
                confettiPalette: [ProviderColor(hex: 0x111111), ProviderColor(hex: 0xD9FF00)]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Jev token cost history is not available." }),
            pace: .unsupported,
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(
                    showsPrimaryBalanceDescription: false,
                    hidesPrimaryResetWithoutDate: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [JevWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "jev",
                aliases: ["typesafe"],
                versionDetector: nil,
                browserSupportExemption: { sourceMode, _, settings in
                    sourceMode == .auto && settings?.jev?.cookieSource == .manual
                }))
    }
}

struct JevWebFetchStrategy: ProviderFetchStrategy {
    let id = "jev.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.settings?.jev?.cookieSource != .off
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        if let manual = context.settings?.jev?.manualCookieHeader,
           context.settings?.jev?.cookieSource == .manual,
           !manual.isEmpty
        {
            let usage = try await JevUsageFetcher.fetchUsage(cookieHeader: manual)
            return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "manual")
        }
        if let cached = CookieHeaderCache.load(provider: .jev) {
            do {
                let usage = try await JevUsageFetcher.fetchUsage(cookieHeader: cached.cookieHeader)
                return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: cached.sourceLabel)
            } catch JevUsageError.loginRequired {
                CookieHeaderCache.clear(provider: .jev)
            }
        }
        #if os(macOS)
        let sessions = try JevCookieImporter.importSessions()
        for session in sessions {
            do {
                let usage = try await JevUsageFetcher.fetchUsage(cookieHeader: session.cookieHeader)
                CookieHeaderCache.store(
                    provider: .jev,
                    cookieHeader: session.cookieHeader,
                    sourceLabel: session.sourceLabel)
                return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: session.sourceLabel)
            } catch JevUsageError.loginRequired {
                continue
            }
        }
        #endif
        throw JevUsageError.missingCookie
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
