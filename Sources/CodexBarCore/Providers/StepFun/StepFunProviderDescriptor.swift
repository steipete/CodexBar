import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum StepFunProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .stepfun,
            metadata: ProviderMetadata(
                id: .stepfun,
                displayName: "StepFun",
                sessionLabel: "5h Window",
                weeklyLabel: "Weekly Window",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show StepFun usage",
                cliName: "stepfun",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://platform.stepfun.com/plan-usage",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .stepfun,
                iconResourceName: "ProviderIcon-stepfun",
                color: ProviderColor(red: 0.13, green: 0.59, blue: 0.95)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "StepFun per-day cost history is not available via API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [StepFunWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "stepfun",
                aliases: ["step-fun", "sf"],
                versionDetector: nil))
    }
}

struct StepFunWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "stepfun.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.settings?.stepfun?.cookieSource != .off
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let cookieSource = context.settings?.stepfun?.cookieSource ?? .auto

        do {
            let token = try await Self.resolveToken(context: context, allowCached: true)
            let usage = try await StepFunUsageFetcher.fetchUsage(token: token)
            return self.makeResult(
                usage: usage.toUsageSnapshot(),
                sourceLabel: "web")
        } catch StepFunUsageError.apiError where cookieSource != .manual {
            // Token may be stale — clear cache and retry with fresh login
            CookieHeaderCache.clear(provider: .stepfun)
            let token = try await Self.resolveToken(context: context, allowCached: false)
            let usage = try await StepFunUsageFetcher.fetchUsage(token: token)
            return self.makeResult(
                usage: usage.toUsageSnapshot(),
                sourceLabel: "web")
        }
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    // MARK: - Token Resolution

    private static func resolveToken(
        context: ProviderFetchContext,
        allowCached: Bool) async throws -> String
    {
        let settings = context.settings?.stepfun

        // 1. Manual mode: use the token directly from settings
        if settings?.cookieSource == .manual {
            let manualToken = settings?.manualToken ?? ""
            guard !manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StepFunUsageError.missingToken
            }
            return StepFunTokenNormalizer.normalize(manualToken)
        }

        // 2. Cached token from previous login
        if allowCached, let cached = CookieHeaderCache.load(provider: .stepfun) {
            return StepFunTokenNormalizer.normalize(cached.cookieHeader)
        }

        // 3. Username + password from Settings UI → perform full login flow
        //    (register device → sign in by password → get Oasis-Token)
        if let settings, !settings.username.isEmpty, !settings.password.isEmpty {
            let token = try await StepFunUsageFetcher.login(
                username: settings.username,
                password: settings.password)
            CookieHeaderCache.store(provider: .stepfun, cookieHeader: token, sourceLabel: "login")
            return token
        }

        // 4. Direct token from env var
        if let token = StepFunSettingsReader.token(environment: context.env) {
            return token
        }

        // 5. Username + password from env vars → perform full login flow
        if let username = StepFunSettingsReader.username(environment: context.env),
           let password = StepFunSettingsReader.password(environment: context.env)
        {
            let token = try await StepFunUsageFetcher.login(username: username, password: password)
            CookieHeaderCache.store(provider: .stepfun, cookieHeader: token, sourceLabel: "login")
            return token
        }

        throw StepFunUsageError.missingCredentials
    }
}

// MARK: - Token Normalizer

public enum StepFunTokenNormalizer {
    /// Normalize a StepFun token value — extracts the Oasis-Token from a cookie header
    /// or returns the raw token value if it's not a cookie header.
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // If it looks like a cookie header, extract Oasis-Token
        if trimmed.contains("Oasis-Token=") {
            let parts = trimmed.components(separatedBy: "Oasis-Token=")
            if parts.count > 1 {
                let afterToken = parts[1]
                return afterToken.components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces) ?? afterToken
            }
        }

        return trimmed
    }
}
