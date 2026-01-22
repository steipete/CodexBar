import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct WindsurfProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .windsurf
    let style: IconStyle = .windsurf

    func makeFetch(context: ProviderBuildContext) -> @Sendable () async throws -> UsageSnapshot {
        {
            let probe = WindsurfStatusProbe()
            let snap = try await probe.fetch()
            return snap.toUsageSnapshot()
        }
    }
}
