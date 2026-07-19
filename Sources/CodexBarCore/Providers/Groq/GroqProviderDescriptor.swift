import Foundation

public enum GroqProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .groq,
            metadata: ProviderMetadata(
                id: .groq,
                displayName: "Groq",
                sessionLabel: "Requests",
                weeklyLabel: "Tokens",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Groq usage",
                cliName: "groqcloud",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://console.groq.com/dashboard/usage",
                statusPageURL: nil,
                statusLinkURL: "https://status.groq.com"),
            branding: ProviderBranding(
                iconStyle: .groq,
                iconResourceName: "ProviderIcon-groq",
                color: ProviderColor(red: 245 / 255, green: 104 / 255, blue: 68 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xF43E01),
                    ProviderColor(hex: 0xFFFFFF),
                    ProviderColor(hex: 0x97FCA7),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Sign in at console.groq.com to show Groq spend and token usage." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    switch context.sourceMode {
                    case .web:
                        [GroqConsoleWebFetchStrategy()]
                    case .api:
                        [Self.prometheusStrategy()]
                    default:
                        [GroqConsoleWebFetchStrategy(), Self.prometheusStrategy()]
                    }
                })),
            cli: ProviderCLIConfig(
                name: "groqcloud",
                aliases: ["groq", "groq-api"],
                versionDetector: nil))
    }

    /// Enterprise-tier Prometheus metrics fallback for org API keys that have
    /// the feature enabled. Standard keys 404 here and simply yield no data.
    private static func prometheusStrategy() -> APITokenFetchStrategy {
        APITokenFetchStrategy(
            id: "groq.api",
            sourceLabel: "metrics",
            resolveToken: { ProviderTokenResolver.groqToken(environment: $0) },
            missingCredentialsError: { GroqUsageError.missingCredentials },
            loadUsage: { apiKey, context in
                try await GroqUsageFetcher.fetchUsage(
                    apiKey: apiKey,
                    environment: context.env).toUsageSnapshot()
            })
    }
}

/// Primary Groq source: the console platform API (`/platform/v1/.../activity`),
/// authenticated with the browser `stytch_session_jwt` session cookie. Returns
/// real spend/token/request history like the OpenAI API provider.
struct GroqConsoleWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "groq.console"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        GroqConsoleSession.hasSession(
            environment: context.env,
            browserDetection: context.browserDetection)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let sessions = GroqConsoleSession.resolveSessions(
            environment: context.env,
            browserDetection: context.browserDetection)
        guard !sessions.isEmpty else {
            throw GroqConsoleError.missingSession
        }

        var lastError: Error?
        for session in sessions {
            do {
                let snapshot = try await GroqConsoleFetcher.fetchUsage(
                    session: session,
                    historyDays: context.costUsageHistoryDays,
                    environment: context.env)
                return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "console")
            } catch {
                guard Self.shouldRetryNextSession(for: error) else { throw error }
                lastError = error
            }
        }
        throw lastError ?? GroqConsoleError.missingSession
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        // Fall back to the Prometheus API key path when there's no usable session.
        guard let consoleError = error as? GroqConsoleError else { return false }
        switch consoleError {
        case .missingSession, .invalidSession, .accessDenied:
            return true
        case .apiError, .parseFailed:
            return false
        }
    }

    private static func shouldRetryNextSession(for error: Error) -> Bool {
        guard let consoleError = error as? GroqConsoleError else { return false }
        switch consoleError {
        case .accessDenied, .invalidSession:
            return true
        case .missingSession, .apiError, .parseFailed:
            return false
        }
    }
}
