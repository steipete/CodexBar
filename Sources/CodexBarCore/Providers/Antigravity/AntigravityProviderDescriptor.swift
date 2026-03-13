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
                defaultEnabled: true,
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
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [AntigravityStatusFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "antigravity",
                versionDetector: nil))
    }
}

struct AntigravityStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "antigravity.local"
    let kind: ProviderFetchKind = .localProbe

    /// Retry delays: 1s, 2s, 4s (exponential backoff for transient probe failures).
    private static let retryDelays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = AntigravityStatusProbe()
        var lastError: Error = AntigravityStatusProbeError.notRunning

        for (attempt, delay) in Self.retryDelays.enumerated() {
            do {
                let snap = try await probe.fetch()
                let usage = try snap.toUsageSnapshot()
                return self.makeResult(usage: usage, sourceLabel: "local")
            } catch AntigravityStatusProbeError.notRunning {
                // Not running is the expected state when Antigravity isn't active.
                // Propagate immediately — no retry needed, this isn't an error condition.
                throw AntigravityStatusProbeError.notRunning
            } catch {
                lastError = error
                let isLastAttempt = attempt == Self.retryDelays.count - 1
                if !isLastAttempt {
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        throw lastError
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
