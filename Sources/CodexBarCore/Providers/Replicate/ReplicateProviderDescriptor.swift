import Foundation
import SweetCookieKit

public enum ReplicateProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Session tokens",
        subtitle: "Store multiple Replicate Cookie headers.",
        placeholder: "Cookie: …",
        injection: .cookieHeader,
        requiresManualCookieSource: true,
        cookieName: nil))

    /// Chrome-only by default to avoid extra Firefox/Safari Keychain and Full Disk Access prompts.
    /// Use Manual cookie source for other browsers.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .replicate,
            settingsSection: .init(ReplicateProviderSettingsKey.self, cookieSettings: ReplicateProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .replicate,
                displayName: "Replicate",
                sessionLabel: "Spend",
                weeklyLabel: "Spend",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Replicate usage",
                cliName: "replicate",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                balanceOnly: false,
                usesDetailBackedWindow: true,
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: ReplicateBillingEndpoints.dashboardURLString,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .replicate),
                iconResourceName: "ProviderIcon-replicate",
                color: ProviderColor(red: 0 / 255, green: 0 / 255, blue: 0 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0x525252),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Replicate spend comes from the billing summary page; cost history is not tracked." }),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(
                    showsPrimaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true,
                    movePrimaryDetailToStatus: { _ in true }),
                menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true })),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [ReplicateWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "replicate",
                aliases: ["r8"],
                versionDetector: nil,
                browserSupportExemption: { _, _, settings in
                    // Manual Cookie headers use plain HTTPS and never import browser data.
                    settings?.replicate?.cookieSource == .manual
                }))
    }
}

struct ReplicateWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "replicate.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.replicate?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let cookieSource = context.settings?.replicate?.cookieSource ?? .auto
        let session = try Self.resolveCookieSession(context: context, allowCached: true)
        do {
            let usage = try await Self.fetchUsage(
                cookieHeader: session.cookieHeader,
                timeout: context.webTimeout)
            return self.makeResult(usage: usage, sourceLabel: "web")
        } catch let error as ReplicateUsageError where cookieSource != .manual && Self.shouldRefreshCachedSession(after: error) {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .replicate)
            let excludedSourceLabels = if session.wasCached {
                Set<String>()
            } else {
                Set([session.sourceLabel].compactMap(\.self))
            }
            let sessions: [ReplicateCookieImporter.SessionInfo]
            do {
                sessions = try ReplicateCookieImporter.importSessions(
                    browserDetection: context.browserDetection,
                    excludingSourceLabels: excludedSourceLabels)
            } catch ReplicateCookieImportError.noCookies {
                throw ReplicateUsageError.invalidCredentials
            }
            let (usage, session) = try await Self.fetchUsageFromSessions(
                sessions,
                timeout: context.webTimeout)
            CookieHeaderCache.store(
                provider: .replicate,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
            return self.makeResult(usage: usage, sourceLabel: "web")
            #else
            throw ReplicateUsageError.invalidCredentials
            #endif
        }
    }

    /// Expired sessions often return same-origin sign-in HTML with HTTP 200, which surfaces as
    /// `invalidCredentials` from account resolution. Refresh automatic/cached cookies for that case.
    private static func shouldRefreshCachedSession(after error: ReplicateUsageError) -> Bool {
        switch error {
        case .invalidCredentials:
            true
        default:
            false
        }
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    #if os(macOS)
    static func fetchUsageFromSessions(
        _ sessions: [ReplicateCookieImporter.SessionInfo],
        timeout: TimeInterval,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws
        -> (usage: UsageSnapshot, session: ReplicateCookieImporter.SessionInfo)
    {
        for session in sessions {
            do {
                let usage = try await Self.fetchUsage(
                    cookieHeader: session.cookieHeader,
                    timeout: timeout,
                    transport: transport)
                return (usage, session)
            } catch ReplicateUsageError.invalidCredentials {
                continue
            }
        }
        throw ReplicateUsageError.invalidCredentials
    }
    #endif

    static func fetchUsage(
        cookieHeader: String,
        timeout: TimeInterval,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> UsageSnapshot
    {
        let html = try await Self.fetchBillingHTML(cookieHeader: cookieHeader, timeout: timeout, transport: transport)
        let account = try ReplicateUsageFetcher.resolveAccount(fromBillingHTML: html)
        let summary = try await ReplicateUsageFetcher.fetchUsage(
            cookieHeader: cookieHeader,
            username: account.username,
            accountKind: account.kind,
            transport: transport)
        return summary.toUsageSnapshot()
    }

    private static func fetchBillingHTML(
        cookieHeader: String,
        timeout: TimeInterval,
        transport: any ProviderHTTPTransport) async throws -> String
    {
        guard let url = URL(string: ReplicateBillingEndpoints.dashboardURLString) else {
            throw ReplicateUsageError.parseFailed("Invalid dashboard URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request, retryPolicy: .transientIdempotent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReplicateUsageError.networkError(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw ReplicateUsageError.invalidCredentials
        case 429:
            throw ReplicateUsageError.rateLimited
        default:
            throw ReplicateUsageError.apiError(response.statusCode)
        }

        guard let html = String(data: response.data, encoding: .utf8) else {
            throw ReplicateUsageError.parseFailed("Non-UTF8 billing HTML")
        }
        return html
    }

    private static func resolveCookieSession(
        context: ProviderFetchContext,
        allowCached: Bool) throws
        -> (cookieHeader: String, sourceLabel: String?, wasCached: Bool)
    {
        if let settings = context.settings?.replicate, settings.cookieSource == .manual {
            guard let header = CookieHeaderNormalizer.normalize(settings.manualCookieHeader) else {
                throw ReplicateUsageError.invalidCookie
            }
            let pairs = CookieHeaderNormalizer.pairs(from: header)
            guard pairs.contains(where: { $0.name == "sessionid" }) else {
                throw ReplicateUsageError.invalidCookie
            }
            return (header, nil, false)
        }

        #if os(macOS)
        if allowCached,
           let cached = CookieHeaderCache.load(provider: .replicate),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return (cached.cookieHeader, cached.sourceLabel, true)
        }
        let session = try ReplicateCookieImporter.importSession(browserDetection: context.browserDetection)
        CookieHeaderCache.store(
            provider: .replicate,
            cookieHeader: session.cookieHeader,
            sourceLabel: session.sourceLabel)
        return (session.cookieHeader, session.sourceLabel, false)
        #else
        throw ReplicateUsageError.missingCookie
        #endif
    }
}
