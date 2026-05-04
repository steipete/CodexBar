import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum MiMoProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .mimo,
            metadata: ProviderMetadata(
                id: .mimo,
                displayName: "MiMo",
                sessionLabel: "Status",
                weeklyLabel: "Models",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show MiMo usage",
                cliName: "mimo",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://platform.xiaomimimo.com/console/balance",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .mimo,
                iconResourceName: "ProviderIcon-mimo",
                color: ProviderColor(red: 1.0, green: 0.55, blue: 0.0)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "MiMo cost summary is not available via API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [MiMoWebFetchStrategy(), MiMoAPIFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "mimo",
                aliases: ["xiaomi", "mimo-v2"],
                versionDetector: nil))
    }
}

struct MiMoAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "mimo.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw MiMoUsageError.missingCredentials
        }
        let usage = try await MiMoUsageFetcher.verifyAPI(apiKey: apiKey)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        true
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.mimoToken(environment: environment)
    }
}

struct MiMoWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "mimo.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.mimoWeb)

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if MiMoCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }

        #if os(macOS)
        if context.settings?.mimo?.cookieSource != .off {
            return MiMoCookieImporter.hasSession()
        }
        #endif

        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let cookieHeader = self.resolveCookieHeader(context: context) else {
            throw MiMoUsageError.missingCookie
        }

        let snapshot = try await MiMoUsageFetcher.fetchBalance(cookieHeader: cookieHeader)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case MiMoUsageError.missingCookie = error { return false }
        return true
    }

    private func resolveCookieHeader(context: ProviderFetchContext) -> String? {
        if let override = MiMoCookieHeader.resolveCookieOverride(context: context) {
            return override.cookieHeader
        }

        #if os(macOS)
        if context.settings?.mimo?.cookieSource != .off {
            do {
                let session = try MiMoCookieImporter.importSession()
                if let header = session.cookieHeader {
                    return header
                }
            } catch {
                Self.log.debug("MiMo browser cookie import failed: \(error)")
            }
        }
        #endif

        return nil
    }
}
