import Foundation

public enum KiloProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(
        supportsAPIKeyOverride: true,
        environmentProjections: [.apiKey(KiloSettingsReader.apiTokenKey)],
        tokenResolver: { kind, environment, authFileURL in
            guard kind == .primary else { return nil }
            if let token = KiloSettingsReader.apiKey(environment: environment) {
                return ProviderTokenResolution(token: token, source: .environment)
            }
            guard let token = KiloSettingsReader.authToken(authFileURL: authFileURL) else { return nil }
            return ProviderTokenResolution(token: token, source: .authFile)
        },
        authDetector: { environment, _ in
            KiloSettingsReader.apiKey(environment: environment) == nil ? [] : ["api"]
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .kilo,
            settingsSection: .init(KiloProviderSettingsKey.self, credentialSettings: { context in
                let source: KiloUsageDataSource = switch context.config?.source {
                case .api: .api
                case .cli: .cli
                case .auto, .web, .oauth, nil: .auto
                }
                let extrasEnabled = source == .auto ? context.config?.extrasEnabled ?? false : false
                return KiloProviderSettings(usageDataSource: source, extrasEnabled: extrasEnabled)
            }),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .kilo,
                displayName: "Kilo",
                sessionLabel: "Credits",
                weeklyLabel: "Kilo Pass",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Kilo usage",
                cliName: "kilo",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Kilo debug log not yet implemented",
                usesDetailBackedWindow: true,
                browserCookieOrder: nil,
                dashboardURL: "https://app.kilo.ai/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .kilo),
                iconResourceName: "ProviderIcon-kilo",
                color: ProviderColor(red: 242 / 255, green: 112 / 255, blue: 39 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xFA483A),
                    ProviderColor(hex: 0xAC1D0E),
                    ProviderColor(hex: 0x121212),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Kilo cost summary is not supported." }),
            presentation: ProviderUsagePresentation(
                identityPresenter: { provider, snapshot in
                    guard let loginMethod = snapshot.loginMethod(for: provider) else {
                        return ProviderIdentityPresentation(badge: nil, plan: nil)
                    }
                    let parts = loginMethod
                        .components(separatedBy: "·")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    guard let first = parts.first else {
                        return ProviderIdentityPresentation(badge: nil, plan: nil)
                    }
                    let firstIsActivity = first.lowercased().hasPrefix("auto top-up:")
                    let plan = firstIsActivity ? nil : UsageFormatter.cleanPlanName(first)
                    let activity = firstIsActivity ? parts : Array(parts.dropFirst())
                    return ProviderIdentityPresentation(
                        badge: plan,
                        plan: plan,
                        details: activity.map { ProviderIdentityPresentation.Detail(label: "Activity", value: $0) })
                },
                menuCard: ProviderMenuCardPresentation(
                    showsPrimaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true),
                menu: ProviderMenuDescriptorPresentation(
                    primaryDescriptionIsDetail: { _ in true },
                    secondaryDescriptionMode: .detailWhenResetDatePresent)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "kilo",
                aliases: ["kilo-ai"],
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .api:
            [KiloAPIFetchStrategy()]
        case .cli:
            [KiloCLIFetchStrategy()]
        case .auto:
            [KiloAPIFetchStrategy(), KiloCLIFetchStrategy()]
        case .web, .oauth:
            []
        }
    }
}

struct KiloAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "kilo.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        // Keep strategy available so missing credentials surface as KiloUsageError.missingCredentials
        // instead of generic ProviderFetchError.noAvailableStrategy.
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = KiloSettingsReader.apiKey(environment: context.env) else {
            throw KiloUsageError.missingCredentials
        }
        let usage = try await KiloUsageFetcher.fetchUsage(apiKey: apiKey, environment: context.env)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        guard let kiloError = error as? KiloUsageError else { return false }
        return kiloError == .missingCredentials || kiloError == .unauthorized
    }
}

struct KiloCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "kilo.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        // Keep strategy available so CLI-specific session failures are surfaced as actionable errors.
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let token = try KiloBearerTokenResolver.resolve(source: .cli, apiKey: nil, environment: context.env).token
        let usage = try await KiloUsageFetcher.fetchUsage(apiKey: token, environment: context.env)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "cli")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
