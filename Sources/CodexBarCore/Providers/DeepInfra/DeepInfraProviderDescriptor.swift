import Foundation

public enum DeepInfraProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .deepinfra,
        displayName: "DeepInfra",
        sessionLabel: "Balance",
        weeklyLabel: "Balance",
        debugLogUnavailableMessage: "DeepInfra debug log not yet implemented",
        balanceOnly: true,
        usesDetailBackedWindow: true,
        dashboardURL: "https://deepinfra.com/dash",
        statusLinkURL: "https://status.deepinfra.com",
        color: .init(hex: 0x2A3275),
        confetti: [0x2A3275, 0x747FDE, 0xFFFFFF],
        noDataMessage: "DeepInfra per-request cost history is not available in CodexBar.",
        environmentKey: "DEEPINFRA_API_KEY",
        environmentAliases: ["DEEPINFRA_TOKEN"],
        missingCredentialMessage: { _ in "Missing DeepInfra API key." },
        tokenAccountSupport: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple DeepInfra API keys.",
            placeholder: "Paste API key…",
            injection: .environment(key: "DEEPINFRA_API_KEY"),
            requiresManualCookieSource: false,
            cookieName: nil),
        presentation: ProviderUsagePresentation(
            menuBarWindowResolver: { context in
                guard context.metric == .automatic,
                      let cost = context.snapshot.providerCost,
                      cost.used.isFinite, cost.limit.isFinite, cost.limit > 0
                else { return .unhandled }
                return .resolved(RateWindow(
                    usedPercent: min(100, max(0, cost.used / cost.limit * 100)),
                    windowMinutes: nil,
                    resetsAt: cost.resetsAt,
                    resetDescription: nil))
            },
            menuCard: ProviderMenuCardPresentation(
                showsPrimaryBalanceDescription: true,
                hidesPrimaryResetWithoutDate: true,
                movePrimaryDetailToStatus: { _ in true }),
            menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true })),
        aliases: ["deep-infra", "di"],
        setup: ProviderSetup(routes: [.init(
            id: "api-key",
            method: .apiKey,
            platforms: [.macOS, .linux],
            requiredInputs: [.init(
                id: "api-key",
                configFields: ["apiKey", "tokenAccounts.accounts[].token"],
                environmentVariables: ["DEEPINFRA_API_KEY", "DEEPINFRA_TOKEN"])],
            command: "codexbar config set-api-key --provider deepinfra --stdin",
            hint: "The command reads a piped API key and saves it as a standalone key. " +
                "A selected API token account overrides the standalone key.")]),
        // Two required 30-second GETs, each with one retry and up to ten seconds of backoff.
        timeout: 145)
}
