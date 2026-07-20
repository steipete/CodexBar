import Foundation

public enum MistralProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .mistral,
            metadata: ProviderMetadata(
                id: .mistral,
                displayName: "Mistral",
                sessionLabel: "Balance",
                weeklyLabel: "",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Mistral usage",
                cliName: "mistral",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.mistralCookieImportOrder,
                dashboardURL: "https://admin.mistral.ai/organization/usage",
                statusPageURL: nil,
                statusLinkURL: "https://status.mistral.ai"),
            branding: ProviderBranding(
                iconStyle: .mistral,
                iconResourceName: "ProviderIcon-mistral",
                color: ProviderColor(red: 255 / 255, green: 80 / 255, blue: 15 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xFA500F),
                    ProviderColor(hex: 0xFFAF01),
                    ProviderColor(hex: 0xFFE000),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "Mistral cost history needs a billing web session." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [MistralWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "mistral",
                aliases: ["mistral-ai"],
                versionDetector: nil))
    }
}

struct MistralWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "mistral.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.mistral?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let cookieSource = context.settings?.mistral?.cookieSource ?? .auto
        let session = try Self.resolveCookieSession(context: context, allowCached: true)
        do {
            let csrf = session.csrfToken
            let usage = try await Self.fetchUsageWithVibe(
                cookieHeader: session.cookieHeader,
                csrfToken: csrf,
                timeout: context.webTimeout)
            return self.makeResult(
                usage: usage,
                sourceLabel: "web")
        } catch MistralUsageError.invalidCredentials where cookieSource != .manual {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .mistral)
            let excludedSourceLabels = if session.wasCached {
                Set<String>()
            } else {
                Set([session.sourceLabel].compactMap(\.self))
            }
            let sessions: [MistralCookieImporter.SessionInfo]
            do {
                sessions = try MistralCookieImporter.importSessions(
                    browserDetection: context.browserDetection,
                    excludingSourceLabels: excludedSourceLabels)
            } catch MistralCookieImportError.noCookies {
                throw MistralUsageError.invalidCredentials
            }
            let (usage, session) = try await Self.fetchUsageFromSessions(
                sessions,
                timeout: context.webTimeout)
            CookieHeaderCache.store(
                provider: .mistral,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
            return self.makeResult(
                usage: usage,
                sourceLabel: "web")
            #else
            throw MistralUsageError.invalidCredentials
            #endif
        }
    }

    #if os(macOS)
    static func fetchUsageFromSessions(
        _ sessions: [MistralCookieImporter.SessionInfo],
        timeout: TimeInterval,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws
        -> (usage: UsageSnapshot, session: MistralCookieImporter.SessionInfo)
    {
        for session in sessions {
            do {
                let csrf = session.csrfToken
                let usage = try await Self.fetchUsageWithVibe(
                    cookieHeader: session.cookieHeader,
                    csrfToken: csrf,
                    timeout: timeout,
                    transport: transport)
                return (usage, session)
            } catch MistralUsageError.invalidCredentials {
                continue
            }
        }
        throw MistralUsageError.invalidCredentials
    }
    #endif

    static func fetchUsageWithVibe(
        cookieHeader: String,
        csrfToken: String?,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> UsageSnapshot
    {
        let deadline = Date().addingTimeInterval(timeout)
        let snapshot = try await MistralUsageFetcher.fetchUsage(
            cookieHeader: cookieHeader,
            csrfToken: csrfToken,
            timeout: timeout,
            transport: transport)
        var remaining = deadline.timeIntervalSinceNow
        let vibeResult: MistralUsageFetcher.MistralVibeUsageResult? = if let csrfToken, remaining > 0 {
            try await Self.fetchOptionalVibeUsage(
                csrfToken: csrfToken,
                cookieHeader: cookieHeader,
                timeout: min(remaining, 4),
                transport: transport)
        } else {
            nil
        }
        remaining = deadline.timeIntervalSinceNow
        let credits: MistralCreditsSnapshot? = if remaining > 0 {
            try await Self.fetchOptionalCredits(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: min(remaining, 4),
                transport: transport)
        } else {
            nil
        }
        return Self.attachVibeWindow(to: snapshot.with(credits: credits).toUsageSnapshot(), vibeResult: vibeResult)
    }

    static func fetchOptionalCredits(
        cookieHeader: String,
        csrfToken: String?,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws
        -> MistralCreditsSnapshot?
    {
        do {
            return try await MistralUsageFetcher.fetchCredits(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: timeout,
                transport: transport)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            return nil
        }
    }

    static func fetchOptionalVibeUsage(
        csrfToken: String,
        cookieHeader: String? = nil,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws
        -> MistralUsageFetcher.MistralVibeUsageResult?
    {
        do {
            return try await MistralUsageFetcher.fetchVibeUsage(
                csrfToken: csrfToken,
                cookieHeader: cookieHeader,
                timeout: timeout,
                transport: transport)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            return nil
        }
    }

    static func attachVibeWindow(
        to usageSnapshot: UsageSnapshot,
        vibeResult: MistralUsageFetcher.MistralVibeUsageResult?) -> UsageSnapshot
    {
        guard let vibeResult else { return usageSnapshot }
        let window = RateWindow(
            usedPercent: vibeResult.usagePercentage,
            windowMinutes: nil,
            resetsAt: vibeResult.resetAt,
            resetDescription: nil)
        let named = NamedRateWindow(id: "mistral-monthly-plan", title: "Monthly Plan", window: window)
        let existing = usageSnapshot.extraRateWindows?.filter { $0.id != named.id } ?? []
        return usageSnapshot.with(extraRateWindows: existing + [named])
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveCookieSession(
        context: ProviderFetchContext,
        allowCached: Bool) throws
        -> (cookieHeader: String, csrfToken: String?, sourceLabel: String?, wasCached: Bool)
    {
        if let settings = context.settings?.mistral, settings.cookieSource == .manual {
            if let header = CookieHeaderNormalizer.normalize(settings.manualCookieHeader) {
                let pairs = CookieHeaderNormalizer.pairs(from: header)
                let hasSessionCookie = pairs.contains { $0.name.hasPrefix("ory_session_") }
                if hasSessionCookie {
                    let csrfToken = pairs.first { $0.name == "csrftoken" }?.value
                    return (header, csrfToken, nil, false)
                }
            }
            throw MistralSettingsError.invalidCookie
        }

        #if os(macOS)
        if allowCached,
           let cached = CookieHeaderCache.load(provider: .mistral),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let pairs = CookieHeaderNormalizer.pairs(from: cached.cookieHeader)
            let csrfToken = pairs.first { $0.name == "csrftoken" }?.value
            return (cached.cookieHeader, csrfToken, cached.sourceLabel, true)
        }
        let session = try MistralCookieImporter.importSession(browserDetection: context.browserDetection)
        CookieHeaderCache.store(
            provider: .mistral,
            cookieHeader: session.cookieHeader,
            sourceLabel: session.sourceLabel)
        return (session.cookieHeader, session.csrfToken, session.sourceLabel, false)
        #else
        throw MistralSettingsError.missingCookie
        #endif
    }
}
