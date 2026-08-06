import Foundation
import SweetCookieKit

public enum LongCatProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(environmentProjections: [
        .cookieHeader(LongCatSettingsReader.cookieHeaderKey, onlyWhenManual: true),
    ])

    /// Preserve Chrome-first behavior, then check Firefox without adding another Keychain prompt.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome, .firefox]
        #else
        nil
        #endif
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .longcat,
            settingsSection: .init(LongCatProviderSettingsKey.self, cookieSettings: LongCatProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .longcat,
                displayName: "LongCat",
                sessionLabel: "Quota",
                weeklyLabel: "Fuel Pack",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show LongCat usage",
                cliName: "longcat",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://longcat.chat/platform/",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .longcat),
                iconResourceName: "ProviderIcon-longcat",
                color: ProviderColor(red: 255 / 255, green: 209 / 255, blue: 0 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xFFD100),
                    ProviderColor(hex: 0x111111),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "LongCat cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [LongCatWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "longcat",
                aliases: ["long-cat", "lc"],
                versionDetector: nil))
    }
}

struct LongCatWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "longcat.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.provider(.longcat, scope: "web"))

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if LongCatCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }

        #if os(macOS)
        if Self.allowsBrowserImport(context: context) {
            return LongCatCookieImporter.hasSession(browserDetection: context.browserDetection)
        }
        #endif

        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot: LongCatUsageSnapshot
        if let override = LongCatCookieHeader.resolveCookieOverride(context: context) {
            snapshot = try await LongCatUsageFetcher.fetchUsage(cookieHeader: override.cookieHeader)
        } else {
            #if os(macOS)
            guard Self.allowsBrowserImport(context: context) else {
                throw LongCatAPIError.missingCookies
            }
            let sessions = try LongCatCookieImporter.importSessions(browserDetection: context.browserDetection)
            snapshot = try await Self.fetchImportedSessions(sessions) { session in
                try await LongCatUsageFetcher.fetchUsage(cookies: session.cookies)
            }
            #else
            throw LongCatAPIError.missingCookies
            #endif
        }
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        if case LongCatAPIError.missingCookies = error {
            return false
        }
        if case LongCatAPIError.invalidSession = error {
            return false
        }
        return true
    }

    #if os(macOS)
    static func fetchImportedSessions(
        _ sessions: [LongCatCookieImporter.SessionInfo],
        fetch: (LongCatCookieImporter.SessionInfo) async throws -> LongCatUsageSnapshot) async throws
        -> LongCatUsageSnapshot
    {
        var lastCredentialError: LongCatAPIError?
        for session in sessions {
            do {
                return try await fetch(session)
            } catch let error as LongCatAPIError {
                switch error {
                case .invalidSession, .missingCookies:
                    lastCredentialError = error
                default:
                    throw error
                }
            }
        }
        throw lastCredentialError ?? LongCatAPIError.missingCookies
    }
    #endif

    /// Browser cookie/keychain import is only used for user-initiated app
    /// refreshes in the Auto source. Manual must use the pasted header and Off
    /// disables web auth, so neither should silently fall back to a browser
    /// session.
    static func allowsBrowserImport(context: ProviderFetchContext) -> Bool {
        let source = context.settings?.longcat?.cookieSource
        return context.runtime == .app &&
            ProviderInteractionContext.current == .userInitiated &&
            (source == nil || source == .auto)
    }
}
