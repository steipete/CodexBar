import Foundation

public enum CommandCodeProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: CommandCodeSettingsReader.apiKeyEnvironmentKey,
        resolve: CommandCodeSettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple Command Code subscription sessions.",
            placeholder: "Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil,
            selectedAccountRequiresManualCookieSource: true,
            passiveSourceModes: [.api]),
        selectedAccountSourceModeResolver: { base, account, _ in
            account == nil ? base : .web
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .commandcode,
            settingsSection: .init(
                CommandCodeProviderSettingsKey.self,
                cookieSettings: CommandCodeProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .commandcode,
                displayName: "Command Code",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: "Monthly",
                supportsOpus: true,
                supportsCredits: true,
                creditsHint: "Monthly USD credits and rolling usage limits from Command Code billing.",
                toggleTitle: "Show Command Code usage",
                cliName: "commandcode",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Command Code debug log not yet implemented",
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://commandcode.ai/studio",
                subscriptionDashboardURL: "https://commandcode.ai/settings/billing",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .commandcode),
                iconResourceName: "ProviderIcon-commandcode",
                color: ProviderColor(hex: 0x8C4EDD),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0xFFFFFF),
                    ProviderColor(hex: 0x8C4EDD),
                ],
                widgetColor: ProviderColor(hex: 0x000000)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Command Code cost summary is not yet supported." }),
            pace: .calendarMonthResetWindow,
            presentation: ProviderUsagePresentation(
                primaryBindingQuotaLanes: [.secondary]),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "commandcode",
                aliases: ["command-code"],
                versionDetector: nil,
                browserSupportExemption: { sourceMode, environment, settings in
                    settings?.commandcode?.cookieSource == .manual ||
                        ((sourceMode == .auto || sourceMode == .api) &&
                            environment.flatMap(CommandCodeSettingsReader.apiKey) != nil)
                }))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        let api = APITokenFetchStrategy(
            id: "commandcode.api",
            reportsMissingCredentials: context.sourceMode == .api,
            resolveToken: CommandCodeSettingsReader.apiKey,
            missingCredentialsError: { CommandCodeUsageError.missingAPIKey },
            loadUsage: { apiKey, _ in
                try await CommandCodeUsageFetcher.fetchUsage(apiKey: apiKey).toUsageSnapshot()
            })
        return switch context.sourceMode {
        case .auto:
            if CommandCodeSettingsReader.apiKey(environment: context.env) != nil {
                [api]
            } else {
                [CommandCodeWebFetchStrategy()]
            }
        case .api: [api]
        case .web: [CommandCodeWebFetchStrategy()]
        case .cli, .oauth: []
        }
    }
}

struct CommandCodeWebFetchStrategy: ProviderFetchStrategy {
    typealias UsageLoader = @Sendable (String) async throws -> CommandCodeUsageSnapshot
    typealias SessionLoader = @Sendable () throws -> any Sequence<CommandCodeResolvedSession>

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
        if context.settings?.commandcode?.cookieSource == .manual {
            guard let manual = Self.manualCookieHeader(from: context) else {
                throw CommandCodeUsageError.missingCredentials
            }
            let snapshot = try await self.usageLoader(manual)
            return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "manual")
        }

        if let cached = CookieHeaderCache.load(provider: .commandcode) {
            do {
                let snapshot = try await self.usageLoader(cached.cookieHeader)
                return self.makeResult(
                    usage: snapshot.toUsageSnapshot(),
                    sourceLabel: cached.sourceLabel)
            } catch CommandCodeUsageError.invalidCredentials {
                _ = CookieHeaderCache.clearIfCurrent(provider: .commandcode, expected: cached)
            } catch {
                throw error
            }
        }

        let sessions: any Sequence<CommandCodeResolvedSession>
        do {
            sessions = try self.sessionLoader()
        } catch {
            throw CommandCodeUsageError.missingCredentials
        }

        do {
            return try await ProviderCandidateRetryRunner.run(
                AnySequence(sessions).lazy.filter { !$0.cookieHeader.isEmpty },
                shouldRetry: { error in
                    (error as? CommandCodeUsageError) == .invalidCredentials
                },
                attempt: { session in
                    let snapshot = try await self.usageLoader(session.cookieHeader)
                    CookieHeaderCache.store(
                        provider: .commandcode,
                        cookieHeader: session.cookieHeader,
                        sourceLabel: session.sourceLabel)
                    return self.makeResult(
                        usage: snapshot.toUsageSnapshot(),
                        sourceLabel: session.sourceLabel)
                })
        } catch ProviderCandidateRetryRunnerError.noCandidates {
            throw CommandCodeUsageError.missingCredentials
        }
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.commandcode?.cookieSource == .manual else { return nil }
        let normalized = CookieHeaderNormalizer.normalize(context.settings?.commandcode?.manualCookieHeader)
        guard let header = normalized, !header.contains("="), !header.contains(";") else { return normalized }
        return CommandCodeCookieHeader.override(from: header)?.headerValue
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func loadAutomaticSessions() throws -> any Sequence<CommandCodeResolvedSession> {
        #if os(macOS)
        try CommandCodeCookieImporter.sessionCandidates().lazy.map { session in
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
