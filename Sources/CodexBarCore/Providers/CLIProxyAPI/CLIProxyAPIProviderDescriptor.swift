import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum CLIProxyAPIProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .cliproxyapi,
            metadata: ProviderMetadata(
                id: .cliproxyapi,
                displayName: "CLIProxyAPI",
                sessionLabel: "Primary",
                weeklyLabel: "Secondary",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show CLIProxyAPI usage",
                cliName: "cliproxyapi",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .cliproxyapi,
                iconResourceName: "ProviderIcon-cliproxyapi",
                color: ProviderColor(red: 52 / 255, green: 120 / 255, blue: 180 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "CLIProxyAPI does not provide cost data." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [CLIProxyAPIManagementFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "cliproxyapi",
                aliases: ["cli-proxy-api"],
                versionDetector: nil))
    }
}

struct CLIProxyAPIManagementFetchStrategy: ProviderFetchStrategy {
    let id: String = "cliproxyapi.management"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        CLIProxyAPISettingsReader.managementURL(environment: context.env) != nil &&
            !(CLIProxyAPISettingsReader.managementKey(environment: context.env)?.isEmpty ?? true)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let baseURL = CLIProxyAPISettingsReader.managementURL(environment: context.env) else {
            throw CLIProxyAPIFetchError.missingManagementURL
        }
        guard let key = CLIProxyAPISettingsReader.managementKey(environment: context.env) else {
            throw CLIProxyAPIFetchError.missingManagementKey
        }

        let client = CLIProxyAPIManagementClient(baseURL: baseURL, managementKey: key)
        let authFiles = try await client.listAuthFiles()
        guard !authFiles.isEmpty else {
            throw CLIProxyAPIFetchError.missingAuthFiles
        }

        let requestedAuthIndex = CLIProxyAPISettingsReader.authIndex(environment: context.env)
        let selected = try self.selectAuthFile(authFiles, authIndex: requestedAuthIndex)
        guard let authIndex = requestedAuthIndex ?? selected.authIndex else {
            throw CLIProxyAPIFetchError.missingAuthIndex
        }

        let quota = try await CLIProxyAPIQuotaFetcher.fetchQuota(
            authFile: selected,
            authIndex: authIndex,
            client: client)
        let usage = UsageSnapshot(
            primary: quota.primary,
            secondary: quota.secondary,
            tertiary: quota.tertiary,
            updatedAt: Date(),
            identity: quota.identity)
        return self.makeResult(usage: usage, sourceLabel: "management")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private func selectAuthFile(_ files: [CLIProxyAPIAuthFile], authIndex: String?) throws -> CLIProxyAPIAuthFile {
        if let authIndex {
            if let match = files.first(where: { $0.authIndex == authIndex }) {
                return match
            }
            throw CLIProxyAPIFetchError.authIndexNotFound
        }
        if let active = files.first(where: { !$0.disabled && !$0.unavailable }) {
            return active
        }
        if let active = files.first(where: { !$0.disabled }) {
            return active
        }
        if let first = files.first {
            return first
        }
        throw CLIProxyAPIFetchError.missingAuthFiles
    }
}

enum CLIProxyAPIFetchError: LocalizedError, Sendable {
    case missingManagementURL
    case missingManagementKey
    case missingAuthFiles
    case missingAuthIndex
    case authIndexNotFound

    var errorDescription: String? {
        switch self {
        case .missingManagementURL:
            "CLIProxyAPI management URL is missing."
        case .missingManagementKey:
            "CLIProxyAPI management key is missing."
        case .missingAuthFiles:
            "CLIProxyAPI auth files are missing."
        case .missingAuthIndex:
            "CLIProxyAPI auth index is missing."
        case .authIndexNotFound:
            "CLIProxyAPI auth index was not found."
        }
    }
}
