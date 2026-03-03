import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum KiloProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .kilo,
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
                browserCookieOrder: nil,
                dashboardURL: "https://app.kilo.ai/account/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .kilo,
                iconResourceName: "ProviderIcon-kilo",
                color: ProviderColor(red: 242 / 255, green: 112 / 255, blue: 39 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Kilo cost summary is not supported." }),
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

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        _ = context
        // Keep strategy available so missing credentials surface as KiloUsageError.missingCredentials
        // instead of generic ProviderFetchError.noAvailableStrategy.
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
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

    private static func resolveToken(environment: [String: String]) -> String? {
        KiloSettingsReader.apiKey(environment: environment)
    }
}

struct KiloCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "kilo.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        _ = context
        // Keep strategy available so CLI-specific session failures are surfaced as actionable errors.
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let token = try Self.resolveToken(environment: context.env)
        let usage = try await KiloUsageFetcher.fetchUsage(apiKey: token, environment: context.env)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "cli")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) throws -> String {
        let authFileURL = Self.authFileURL(environment: environment)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: authFileURL.path) else {
            throw KiloUsageError.cliSessionMissing(authFileURL.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: authFileURL)
        } catch {
            throw KiloUsageError.cliSessionUnreadable(authFileURL.path)
        }

        guard let token = KiloSettingsReader.parseAuthToken(data: data) else {
            throw KiloUsageError.cliSessionInvalid(authFileURL.path)
        }

        return token
    }

    private static func authFileURL(environment: [String: String]) -> URL {
        if let home = KiloSettingsReader.cleaned(environment["HOME"]) {
            let expandedHome = NSString(string: home).expandingTildeInPath
            return KiloSettingsReader.defaultAuthFileURL(
                homeDirectory: URL(fileURLWithPath: expandedHome, isDirectory: true))
        }
        return KiloSettingsReader.defaultAuthFileURL(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }
}
