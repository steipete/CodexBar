import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum MistralProviderDescriptor {
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
                supportsTokenCost: false,
                noDataMessage: { "Mistral cost summary is not yet supported." }),
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
            let snapshot = try await MistralUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: context.webTimeout)
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
        } catch MistralUsageError.invalidCredentials where cookieSource != .manual {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .mistral)
            let (cookieHeader, csrfToken) = try Self.resolveCookieHeader(context: context, allowCached: false)
            let snapshot = try await MistralUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: context.webTimeout)
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
            #else
            throw MistralUsageError.invalidCredentials
            #endif
        }
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
