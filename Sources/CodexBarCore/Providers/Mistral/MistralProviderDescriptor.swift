import Foundation

public enum MistralProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .mistral,
            metadata: ProviderMetadata(
                id: .mistral,
                displayName: "Mistral",
                sessionLabel: "Monthly",
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
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://admin.mistral.ai/organization/usage",
                statusPageURL: nil,
                statusLinkURL: "https://status.mistral.ai"),
            branding: ProviderBranding(
                iconStyle: .mistral,
                iconResourceName: "ProviderIcon-mistral",
                color: ProviderColor(red: 255 / 255, green: 80 / 255, blue: 15 / 255)),
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
        do {
            let (cookieHeader, csrfToken) = try Self.resolveCookieHeader(context: context, allowCached: true)
            let usage = try await Self.fetchUsageWithVibe(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: context.webTimeout)
            return self.makeResult(
                usage: usage,
                sourceLabel: "web")
        } catch MistralUsageError.invalidCredentials where cookieSource != .manual {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .mistral)
            let (cookieHeader, csrfToken) = try Self.resolveCookieHeader(context: context, allowCached: false)
            let usage = try await Self.fetchUsageWithVibe(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: context.webTimeout)
            return self.makeResult(
                usage: usage,
                sourceLabel: "web")
            #else
            throw MistralUsageError.invalidCredentials
            #endif
        }
    }

    private static func fetchUsageWithVibe(
        cookieHeader: String,
        csrfToken: String?,
        timeout: TimeInterval) async throws -> UsageSnapshot
    {
        let deadline = Date().addingTimeInterval(timeout)
        let snapshot = try await MistralUsageFetcher.fetchUsage(
            cookieHeader: cookieHeader,
            csrfToken: csrfToken,
            timeout: timeout)
        let remaining = deadline.timeIntervalSinceNow
        let vibeResult: MistralUsageFetcher.MistralVibeUsageResult? = if let csrfToken, remaining > 0 {
            try await Self.fetchOptionalVibeUsage(
                csrfToken: csrfToken,
                cookieHeader: cookieHeader,
                timeout: min(remaining, 4))
        } else {
            nil
        }
        return Self.attachVibeWindow(to: snapshot.toUsageSnapshot(), vibeResult: vibeResult)
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

    private static func resolveCookieHeader(
        context: ProviderFetchContext,
        allowCached: Bool) throws -> (cookieHeader: String, csrfToken: String?)
    {
        if let settings = context.settings?.mistral, settings.cookieSource == .manual {
            if let header = CookieHeaderNormalizer.normalize(settings.manualCookieHeader) {
                let pairs = CookieHeaderNormalizer.pairs(from: header)
                let hasSessionCookie = pairs.contains { $0.name.hasPrefix("ory_session_") }
                if hasSessionCookie {
                    let csrfToken = pairs.first { $0.name == "csrftoken" }?.value
                    return (header, csrfToken)
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
            return (cached.cookieHeader, csrfToken)
        }
        let session = try MistralCookieImporter.importSession(browserDetection: context.browserDetection)
        CookieHeaderCache.store(
            provider: .mistral,
            cookieHeader: session.cookieHeader,
            sourceLabel: session.sourceLabel)
        return (session.cookieHeader, session.csrfToken)
        #else
        throw MistralSettingsError.missingCookie
        #endif
    }
}
