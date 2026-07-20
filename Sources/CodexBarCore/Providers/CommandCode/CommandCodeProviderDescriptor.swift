import Foundation

public enum CommandCodeProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .commandcode,
            metadata: ProviderMetadata(
                id: .commandcode,
                displayName: "Command Code",
                sessionLabel: "Monthly credits",
                weeklyLabel: "Monthly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Monthly USD credits from Command Code billing.",
                toggleTitle: "Show Command Code usage",
                cliName: "commandcode",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://commandcode.ai/studio",
                subscriptionDashboardURL: "https://commandcode.ai/settings/billing",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .commandcode,
                iconResourceName: "ProviderIcon-commandcode",
                color: ProviderColor(hex: 0xA04DFD),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0xFFFFFF),
                    ProviderColor(hex: 0x7B5BFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Command Code cost summary is not yet supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [CommandCodeWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "commandcode",
                aliases: ["command-code"],
                versionDetector: nil))
    }
}

struct CommandCodeWebFetchStrategy: ProviderFetchStrategy {
    typealias UsageLoader = @Sendable (String) async throws -> CommandCodeUsageSnapshot
    typealias SessionLoader = @Sendable () throws -> [CommandCodeResolvedSession]

    let id: String = "commandcode.web"
    let kind: ProviderFetchKind = .web
    private let usageLoader: UsageLoader
    private let sessionLoader: SessionLoader

    init(
        usageLoader: @escaping UsageLoader = { cookieHeader in
            try await CommandCodeUsageFetcher.fetchUsage(cookieHeader: cookieHeader)
        },
        sessionLoader: @escaping SessionLoader = CommandCodeWebFetchStrategy.loadAutomaticSessions)
    {
        self.usageLoader = usageLoader
        self.sessionLoader = sessionLoader
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.commandcode?.cookieSource != .off else { return false }
        if Self.manualCookieHeader(from: context) != nil {
            return true
        }
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        if let manual = Self.manualCookieHeader(from: context) {
            let snapshot = try await self.usageLoader(manual)
            return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "manual")
        }

        let sessions: [CommandCodeResolvedSession]
        do {
            sessions = try self.sessionLoader()
        } catch {
            throw CommandCodeUsageError.missingCredentials
        }

        let candidates = sessions.filter { !$0.cookieHeader.isEmpty }
        guard !candidates.isEmpty else { throw CommandCodeUsageError.missingCredentials }

        return try await ProviderCandidateRetryRunner.run(
            candidates,
            shouldRetry: { error in
                (error as? CommandCodeUsageError) == .invalidCredentials
            },
            attempt: { session in
                let snapshot = try await self.usageLoader(session.cookieHeader)
                return self.makeResult(
                    usage: snapshot.toUsageSnapshot(),
                    sourceLabel: session.sourceLabel)
            })
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.commandcode?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.commandcode?.manualCookieHeader)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func loadAutomaticSessions() throws -> [CommandCodeResolvedSession] {
        #if os(macOS)
        try CommandCodeCookieImporter.importSessions().map { session in
            CommandCodeResolvedSession(
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
        }
        #else
        []
        #endif
    }
}

struct CommandCodeResolvedSession: Sendable {
    let cookieHeader: String
    let sourceLabel: String
}
