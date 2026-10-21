import Foundation

public enum FutureAGIProviderDescriptor {
    public static let spec = PluginProviderSpec(
        id: .futureagi,
        displayName: "Future AGI",
        sessionLabel: "AI credits",
        weeklyLabel: "Gateway requests",
        dashboardURL: "https://app.futureagi.com/dashboard/settings/usage-summary",
        color: .init(hex: 0x7857FC),
        confetti: [0x7857FC, 0xCF6BE8],
        noDataMessage: "Future AGI cost history is not available.",
        environmentKey: "FI_API_KEY",
        missingCredentialMessage: { _ in "Set both FI_API_KEY and FI_SECRET_KEY, or enter them in Settings." },
        additionalProjections: [.init(key: "FI_SECRET_KEY", value: { $0.pluginSecrets?["FI_SECRET_KEY"] })],
        apiKeyField: .init(
            id: "futureagi-api-key",
            title: "API key",
            subtitle: "Saved in CodexBar's local config file. Or set FI_API_KEY."))

    public static let descriptor = Self.spec.makeDescriptor(fetchPlan: ProviderFetchPlan(
        sourceModes: [.auto, .api],
        pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
            [ScriptFetchStrategy(
                id: "futureagi.js",
                provider: .futureagi,
                bundledPlugin: "futureagi",
                sourceLabel: "api",
                validateContext: { context in
                    guard SettingsValue.cleaned(context.env["FI_API_KEY"]) != nil,
                          SettingsValue.cleaned(context.env["FI_SECRET_KEY"]) != nil
                    else {
                        throw ProviderFetchClassifiedError(
                            kind: .missingCredential,
                            message: "Future AGI requires both FI_API_KEY and FI_SECRET_KEY.")
                    }
                },
                resolveValues: { context in
                    .init(secrets: ["FI_API_KEY", "FI_SECRET_KEY"].reduce(into: [:]) { values, key in
                        values[key] = SettingsValue.cleaned(context.env[key])
                    })
                },
                isEnabled: { _ in true })]
        })))
}
