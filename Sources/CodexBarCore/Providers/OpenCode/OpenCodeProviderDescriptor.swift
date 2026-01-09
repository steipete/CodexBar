import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum OpenCodeProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .opencode,
            metadata: ProviderMetadata(
                id: .opencode,
                displayName: "OpenCode",
                sessionLabel: "Cost",
                weeklyLabel: "Avg/Day",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show OpenCode usage",
                cliName: "opencode",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://opencode.ai",
                statusPageURL: nil,
                statusLinkURL: "https://opencode.ai"),
            branding: ProviderBranding(
                iconStyle: .opencode,
                iconResourceName: "ProviderIcon-opencode",
                // OpenCode brand color - teal/cyan
                color: ProviderColor(red: 0 / 255, green: 200 / 255, blue: 200 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "OpenCode cost tracking requires usage data. Run some sessions first." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [OpenCodeCLIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "opencode",
                aliases: [],
                versionDetector: { _ in OpenCodeStatusProbe.detectVersion() }))
    }
}

struct OpenCodeCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "opencode.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        // Check if opencode binary exists
        let possiblePaths = [
            "\(NSHomeDirectory())/.opencode/bin/opencode",
            "\(NSHomeDirectory())/.local/share/opencode/bin/opencode",
            "/usr/local/bin/opencode",
            "/opt/homebrew/bin/opencode",
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }

        return TTYCommandRunner.which("opencode") != nil
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = OpenCodeStatusProbe()
        let snap = try await probe.fetch()
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "cli")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
