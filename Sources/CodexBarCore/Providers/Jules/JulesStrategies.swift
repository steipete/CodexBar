import Foundation

struct JulesFetchStrategy: ProviderFetchStrategy {
    let id: String = "jules.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        // Use TTYCommandRunner.which which is a synchronous static method, no await needed.
        return TTYCommandRunner.which("jules") != nil
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = JulesStatusProbe()
        let snap = try await probe.fetch()
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "cli")
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        // If authentication fails, we don't fallback, we just report it.
        if let julesError = error as? JulesStatusProbeError {
            switch julesError {
            case .notLoggedIn, .julesNotInstalled:
                return false
            default:
                return true
            }
        }
        return false
    }
}
