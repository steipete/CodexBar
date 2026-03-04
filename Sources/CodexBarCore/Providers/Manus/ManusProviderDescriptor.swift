import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum ManusProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .manus,
            metadata: ProviderMetadata(
                id: .manus,
                displayName: "Manus",
                sessionLabel: "Credits",
                weeklyLabel: "Credits",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Shows remaining Manus AI credits.",
                toggleTitle: "Show Manus usage",
                cliName: "manus",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://manus.im",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .manus,
                iconResourceName: "ProviderIcon-manus",
                color: ProviderColor(red: 30 / 255, green: 30 / 255, blue: 30 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Manus cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [ManusWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "manus",
                aliases: [],
                versionDetector: nil))
    }
}

struct ManusWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "manus.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.manusUsage)

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if let token = self.resolveToken(context: context), !token.isEmpty {
            return true
        }
        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let token = self.resolveToken(context: context) else {
            throw ManusAPIError.missingToken
        }

        let response = try await ManusUsageFetcher.fetchUsage(sessionToken: token)
        return self.makeResult(
            usage: response.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case ManusAPIError.missingToken = error { return false }
        if case ManusAPIError.invalidToken = error { return false }
        return true
    }

    private func resolveToken(context: ProviderFetchContext) -> String? {
        // Manual cookie override from settings (highest priority when set)
        if let settings = context.settings?.manus, settings.cookieSource == .manual {
            if let manual = settings.manualCookieHeader, !manual.isEmpty {
                return manual
            }
        }

        // Try browser cookie import when auto mode is enabled
        #if os(macOS)
        if context.settings?.manus?.cookieSource != .off {
            do {
                let session = try ManusCookieImporter.importSession()
                if let token = session.sessionToken {
                    return token
                }
            } catch {
                // No browser cookies found; fall through
            }
        }
        #endif

        // Fall back to environment variable
        return ProviderTokenResolver.manusSessionToken(environment: context.env)
    }
}
