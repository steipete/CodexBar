import Foundation

public enum CursorProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .cursor,
            metadata: ProviderMetadata(
                id: .cursor,
                displayName: "Cursor",
                sessionLabel: "Total",
                weeklyLabel: "Auto",
                opusLabel: "API",
                supportsOpus: true,
                supportsCredits: true,
                creditsHint: "On-demand usage beyond included plan limits.",
                toggleTitle: "Show Cursor usage",
                cliName: "cursor",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.cursorCookieImportOrder
                    ?? ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://cursor.com/dashboard?tab=usage",
                statusPageURL: "https://status.cursor.com",
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .cursor,
                iconResourceName: "ProviderIcon-cursor",
                color: ProviderColor(red: 0 / 255, green: 191 / 255, blue: 165 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x1B1913),
                    ProviderColor(hex: 0xEDECEC),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No Cursor cost usage found. Sign in to Cursor in your browser or the Cursor app." }),
            pace: ProviderPaceCapability(resetWindowPace: .windowDurationPresent),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .web, .oauth],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "cursor",
                versionDetector: nil))
    }

    @Sendable
    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        #if os(macOS) || os(Linux)
        switch context.sourceMode {
        case .oauth:
            return [CursorAppTokenFetchStrategy()]
        case .web, .cli:
            // Cli is only ever set by the shell for "no cookie yet"; treat it as
            // web so empty-manual users get a browser cookie attempt (#212).
            return [CursorStatusFetchStrategy()]
        case .auto:
            let appToken = CursorAppTokenFetchStrategy()
            // When the app token will run first, the web ladder must not retry
            // the same token as its own last-resort fallback.
            let appTokenAvailable = await appToken.isAvailable(context)
            return [appToken, CursorStatusFetchStrategy(allowAppAuthFallback: !appTokenAvailable)]
        case .api:
            return []
        }
        #else
        return [CursorStatusFetchStrategy()]
        #endif
    }
}

struct CursorStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "cursor.web"
    let kind: ProviderFetchKind = .web
    let allowAppAuthFallback: Bool

    init(allowAppAuthFallback: Bool = true) {
        self.allowAppAuthFallback = allowAppAuthFallback
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.cursor?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = CursorStatusProbe(browserDetection: context.browserDetection)
        let manual = Self.manualCookieHeader(from: context)
        let snap = try await probe.fetch(
            cookieHeaderOverride: manual,
            allowAppAuthFallback: self.allowAppAuthFallback)
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.cursor?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.cursor?.manualCookieHeader)
    }
}

#if os(macOS) || os(Linux)
/// Fetches usage with the Cursor desktop app's locally stored access token,
/// mirroring the Codex/Claude pattern of preferring a local credential over
/// browser cookies.
struct CursorAppTokenFetchStrategy: ProviderFetchStrategy {
    let id: String = "cursor.oauth"
    let kind: ProviderFetchKind = .oauth

    private let appAuthStore: any CursorAppAuthSessionProviding
    private let loadCachedEntry: @Sendable () -> CookieHeaderCache.Entry?

    init(
        appAuthStore: any CursorAppAuthSessionProviding = CursorAppAuthStore(),
        loadCachedEntry: @escaping @Sendable () -> CookieHeaderCache.Entry? = {
            CookieHeaderCache.load(provider: .cursor)
        })
    {
        self.appAuthStore = appAuthStore
        self.loadCachedEntry = loadCachedEntry
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Explicit account choices must keep winning automatic mode: a manual
        // cookie header (or selected token account) and an explicitly selected
        // browser login both outrank the app token.
        if context.sourceMode == .auto {
            if context.settings?.cursor?.cookieSource == .manual,
               CookieHeaderNormalizer.normalize(context.settings?.cursor?.manualCookieHeader) != nil
            {
                return false
            }
            if self.loadCachedEntry()?.authenticationFailurePolicy == .stopFallback {
                return false
            }
        }
        guard let session = try? self.appAuthStore.loadSession() else { return false }
        return session.isUsable
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let session = try self.appAuthStore.loadSession(), session.isUsable else {
            throw CursorStatusProbeError.notLoggedIn
        }
        let probe = CursorStatusProbe(browserDetection: context.browserDetection)
        let snap = try await probe.fetchWithAppAuthSession(session)
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "app")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}
#endif
