import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum GroqProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .groq,
            metadata: ProviderMetadata(
                id: .groq,
                displayName: "Groq",
                sessionLabel: "Spend",
                weeklyLabel: "Requests",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Groq usage",
                cliName: "groq",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://console.groq.com/settings/usage",
                subscriptionDashboardURL: "https://console.groq.com/settings/billing",
                statusPageURL: nil,
                statusLinkURL: "https://groqstatus.com"),
            branding: ProviderBranding(
                iconStyle: .groq,
                iconResourceName: "ProviderIcon-groq",
                color: ProviderColor(red: 0.96, green: 0.31, blue: 0.21)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Groq token cost history is not available via this endpoint." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    switch context.sourceMode {
                    case .web: [GroqCookieFetchStrategy()]
                    case .api: [GroqAPIFetchStrategy()]
                    default: [GroqCookieFetchStrategy(), GroqAPIFetchStrategy()]
                    }
                })),
            cli: ProviderCLIConfig(
                name: "groq",
                aliases: [],
                versionDetector: nil))
    }
}

// Reads stytch_session_jwt from the browser — no manual token needed.
struct GroqCookieFetchStrategy: ProviderFetchStrategy {
    let id: String = "groq.cookie"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        #if os(macOS)
        return GroqCookieImporter.hasSession(browserDetection: context.browserDetection)
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        #if os(macOS)
        let session = try GroqCookieImporter.importSession(browserDetection: context.browserDetection)
        guard let orgID = session.orgID else {
            throw GroqUsageError.missingOrgID
        }
        let snapshot = try await GroqActivityFetcher.fetchActivity(
            token: session.jwt,
            orgID: orgID,
            environment: context.env)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "cookie (\(session.sourceLabel))")
        #else
        throw GroqUsageError.missingCredentials
        #endif
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        if let importError = error as? GroqCookieImportError,
           case .noCookies = importError { return true }
        return false
    }
}

struct GroqAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "groq.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard let token = ProviderTokenResolver.groqToken(environment: context.env) else { return false }
        return GroqSettingsReader.extractOrgID(fromJWT: token) != nil
            || GroqSettingsReader.orgID(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let token = ProviderTokenResolver.groqToken(environment: context.env) else {
            throw GroqUsageError.missingCredentials
        }
        guard let orgID = GroqSettingsReader.orgID(environment: context.env) else {
            throw GroqUsageError.missingOrgID
        }
        let snapshot = try await GroqActivityFetcher.fetchActivity(
            token: token,
            orgID: orgID,
            environment: context.env)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
