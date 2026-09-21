import Foundation

public enum GitKrakenProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: GitKrakenSettingsReader.tokenKey,
        apiKeyDebugLabel: "GitKraken access token",
        additionalProjections: [.workspaceID(GitKrakenSettingsReader.organizationKey)],
        resolve: GitKrakenSettingsReader.accessToken)

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .gitkraken,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 7),
            metadata: ProviderMetadata(
                id: .gitkraken,
                displayName: "GitKraken AI",
                sessionLabel: "Personal",
                weeklyLabel: "Shared pool",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show GitKraken AI usage",
                cliName: "gk",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://gitkraken.dev/account#ai-usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .gitkraken),
                iconResourceName: "ProviderIcon-gitkraken",
                color: ProviderColor(hex: 0x179287),
                confettiPalette: [ProviderColor(hex: 0x179287), ProviderColor(hex: 0x9DE5D2)]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "GitKraken cost summaries are not supported." }),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(clearsPrimaryReset: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "gk",
                aliases: ["gitkraken"],
                versionDetector: { _ in GitKrakenCLIProbe.version() }))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .auto: [GitKrakenAPIFetchStrategy(), GitKrakenCLIFetchStrategy()]
        case .api: [GitKrakenAPIFetchStrategy()]
        case .cli: [GitKrakenCLIFetchStrategy()]
        case .web, .oauth: []
        }
    }
}

struct GitKrakenAPIFetchStrategy: ProviderFetchStrategy {
    let id = "gitkraken.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.sourceMode == .api ||
            GitKrakenSettingsReader.accessToken(environment: context.env) != nil ||
            GitKrakenSettingsReader.organizationID(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let token = GitKrakenSettingsReader.accessToken(environment: context.env) else {
            throw GitKrakenUsageError.missingToken
        }
        let usage = try await GitKrakenUsageFetcher.fetch(
            token: token,
            organizationID: GitKrakenSettingsReader.organizationID(environment: context.env))
        return self.makeResult(usage: usage.toUsageSnapshot(source: "API"), sourceLabel: "api")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto,
              GitKrakenSettingsReader.organizationID(environment: context.env) == nil,
              !(error is CancellationError), (error as? URLError)?.code != .cancelled,
              (error as? GitKrakenUsageError) != .httpError(429)
        else { return false }
        return true
    }
}

struct GitKrakenCLIFetchStrategy: ProviderFetchStrategy {
    let id = "gitkraken.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // A configured API organization cannot silently become the CLI's potentially different organization.
        context.sourceMode == .cli || GitKrakenSettingsReader.organizationID(environment: context.env) == nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let executable = GitKrakenCLIProbe.executable(
            environment: context.env,
            loginPATH: LoginShellPathCache.shared.current)
        else { throw SubprocessRunnerError.binaryNotFound("gk") }
        let usage = try await GitKrakenCLIProbe().fetch(executable: executable, environment: context.env)
        return self.makeResult(usage: usage.toUsageSnapshot(source: "CLI"), sourceLabel: "cli")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
