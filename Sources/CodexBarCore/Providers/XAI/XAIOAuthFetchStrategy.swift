import Foundation

public enum XAIOAuthUsageMapper {
    public static let superGrokPlan = "SuperGrok"
    public static let superGrokUsageDashboardURL = "https://grok.com/?_s=usage"

    public static func usageSnapshot(
        credits: XAIOAuthCreditsSnapshot,
        updatedAt: Date = Date()) -> UsageSnapshot
    {
        let primary: RateWindow? =
            if let percent = credits.usedPercent {
                RateWindow(
                    usedPercent: percent,
                    windowMinutes: nil,
                    resetsAt: credits.resetsAt,
                    resetDescription: nil)
            } else {
                nil
            }
        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .xai,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: self.planName(from: credits.subscriptionTier)))
    }

    public static func planName(from subscriptionTier: String?) -> String {
        self.displayName(from: subscriptionTier) ?? self.superGrokPlan
    }

    public static func isSuperGrokFamily(_ loginMethod: String?) -> Bool {
        let token = self.compactToken(loginMethod ?? "")
        return token.contains("supergrok") || token == "heavy"
    }

    public static func displayName(from raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        switch self.compactToken(trimmed) {
        case "supergrokheavy", "heavy":
            return "SuperGrok Heavy"
        case "supergrok":
            return "SuperGrok"
        default:
            return trimmed
        }
    }

    public static func omitsIncludedUsagePercent(_ raw: String?) -> Bool {
        self.compactToken(raw ?? "").contains("heavy")
    }

    private static func compactToken(_ raw: String) -> String {
        raw.lowercased().filter(\.isLetter)
    }
}

struct XAIOAuthFetchStrategy: ProviderFetchStrategy {
    let id: String = "xai.oauth"
    let kind: ProviderFetchKind = .oauth
    private let creditsFetch: @Sendable (String) async throws -> XAIOAuthCreditsSnapshot

    init(
        creditsFetch: @escaping @Sendable (String) async throws -> XAIOAuthCreditsSnapshot = {
            try await XAIOAuthCreditsFetcher.fetch(accessToken: $0)
        })
    {
        self.creditsFetch = creditsFetch
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        XAISettingsReader.oauthAccessToken(
            environment: context.env, settings: context.settings?.xai) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard
            let token = XAISettingsReader.oauthAccessToken(
                environment: context.env,
                settings: context.settings?.xai)
        else {
            throw ProviderFetchClassifiedError(
                kind: .missingCredential,
                message: XAIOAuthCreditsFetcher.missingTokenMessage)
        }
        let credits = try await self.creditsFetch(token)
        return self.makeResult(
            usage: XAIOAuthUsageMapper.usageSnapshot(credits: credits),
            sourceLabel: "oauth")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        (context.sourceMode == .auto || context.sourceMode == .web)
            && !(error is CancellationError)
    }
}
