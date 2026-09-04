import Foundation
import SweetCookieKit

public enum HelmcodeProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(environmentProjections: [
        .cookieHeader(HelmcodeSettingsReader.cookieHeaderEnvironmentKey, onlyWhenManual: true),
    ])

    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .helmcode,
            settingsSection: .init(HelmcodeProviderSettingsKey.self, cookieSettings: HelmcodeProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .helmcode,
                displayName: "Helmcode",
                sessionLabel: "Monthly",
                weeklyLabel: "Monthly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Helmcode usage",
                cliName: "helmcode",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Helmcode debug log not yet implemented",
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://cloud.helmcode.com/credits",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .helmcode),
                iconResourceName: "ProviderIcon-helmcode",
                color: ProviderColor(hex: 0x4934E1),
                confettiPalette: [
                    ProviderColor(hex: 0x4934E1),
                    ProviderColor(hex: 0x8B7CF6),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Helmcode per-request cost history is not available in CodexBar." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { _ in
                    ProviderCostPresentation(menuCardStyle: .prepaidCredits)
                },
                extraRateWindowSelector: { $0.extraRateWindows ?? [] },
                menuCard: ProviderMenuCardPresentation(showsPrimaryBalanceDescription: true),
                menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true })),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [HelmcodeWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "helmcode",
                aliases: ["helm-code"],
                versionDetector: nil))
    }
}

struct HelmcodeWebFetchStrategy: ProviderFetchStrategy {
    let id = "helmcode.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if HelmcodeCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }

        #if os(macOS)
        if Self.allowsBrowserImport(context: context) {
            return HelmcodeCookieImporter.hasSession(browserDetection: context.browserDetection)
        }
        #endif

        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot: HelmcodeUsageSnapshot
        if let override = HelmcodeCookieHeader.resolveCookieOverride(context: context) {
            snapshot = try await HelmcodeUsageFetcher.fetchUsage(cookieHeader: override.cookieHeader)
        } else {
            #if os(macOS)
            guard Self.allowsBrowserImport(context: context) else {
                throw HelmcodeUsageError.missingCookies
            }
            let sessions = try HelmcodeCookieImporter.importSessions(browserDetection: context.browserDetection)
            snapshot = try await Self.fetchImportedSessions(sessions) { session in
                try await HelmcodeUsageFetcher.fetchUsage(cookies: session.cookies)
            }
            #else
            throw HelmcodeUsageError.missingCookies
            #endif
        }
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    static func allowsBrowserImport(context: ProviderFetchContext) -> Bool {
        let source = context.settings?.helmcode?.cookieSource
        return context.runtime == .app &&
            ProviderInteractionContext.current == .userInitiated &&
            (source == nil || source == .auto)
    }

    #if os(macOS)
    static func fetchImportedSessions(
        _ sessions: [HelmcodeCookieImporter.SessionInfo],
        fetch: (HelmcodeCookieImporter.SessionInfo) async throws -> HelmcodeUsageSnapshot) async throws
        -> HelmcodeUsageSnapshot
    {
        var lastCredentialError: HelmcodeUsageError?
        for session in sessions {
            do {
                return try await fetch(session)
            } catch let error as HelmcodeUsageError {
                switch error {
                case .invalidSession, .missingCookies:
                    lastCredentialError = error
                case .rateLimited, .apiError, .parseFailed:
                    throw error
                }
            }
        }
        throw lastCredentialError ?? HelmcodeUsageError.missingCookies
    }
    #endif
}
