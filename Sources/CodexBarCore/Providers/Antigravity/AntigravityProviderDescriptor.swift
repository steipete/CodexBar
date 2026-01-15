import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum AntigravityProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .antigravity,
            metadata: ProviderMetadata(
                id: .antigravity,
                displayName: "Antigravity",
                sessionLabel: "Claude",
                weeklyLabel: "Gemini Pro",
                opusLabel: "Gemini Flash",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Antigravity usage (experimental)",
                cliName: "antigravity",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: nil,
                statusPageURL: nil,
                statusLinkURL: "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history",
                statusWorkspaceProductID: "npdyhgECDJ6tB66MxXyo"),
            branding: ProviderBranding(
                iconStyle: .antigravity,
                iconResourceName: "ProviderIcon-antigravity",
                color: ProviderColor(red: 96 / 255, green: 186 / 255, blue: 126 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Antigravity cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [AntigravityAPIFetchStrategy(), AntigravityStatusFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "antigravity",
                versionDetector: nil))
    }
}

struct AntigravityStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "antigravity.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_: ProviderFetchContext) async -> Bool { true }

    func fetch(context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = AntigravityStatusProbe()
        let snap = try await probe.fetch()
        let usage = try snap.toUsageSnapshot()
        return self.makeResult(
            usage: usage,
            sourceLabel: "local")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

struct AntigravityAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "antigravity.api"
    let kind: ProviderFetchKind = .apiFetch

    func isAvailable(context: ProviderFetchContext) async -> Bool {
        let hasAccounts = (try? context.settings.antigravityAccounts)?.accounts.isEmpty == false
        return hasAccounts
    }

    func fetch(context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let accounts = context.settings.antigravityAccounts?.accounts ?? []
        let currentIndex = context.settings.antigravityCurrentAccountIndex
        guard currentIndex < accounts.count else {
            throw AntigravityStatusProbeError.parseFailed("No account selected")
        }
        let account = accounts[currentIndex]

        let probe = AntigravityAPIProbe(account: account)
        let snap = try await probe.fetch()
        let usage = try snap.toUsageSnapshot()
        return self.makeResult(
            usage: usage,
            sourceLabel: account.email)
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
