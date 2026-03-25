import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct AntigravityProviderDescriptorTests {
    private func makeContext(sourceMode: ProviderSourceMode) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private func strategyIDs(sourceMode: ProviderSourceMode) async -> [String] {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .antigravity)
        let context = self.makeContext(sourceMode: sourceMode)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        return strategies.map(\.id)
    }

    @Test
    func `auto source defaults to local before oauth`() async {
        await AntigravitySessionState.setPreferRemote(false)
        #expect(await AntigravitySessionState.preferRemote() == false)

        let strategyIDs = await self.strategyIDs(sourceMode: .auto)

        #expect(strategyIDs == ["antigravity.local", "antigravity.api"])
    }

    @Test
    func `auto source prefers oauth after explicit account switch`() async {
        await AntigravitySessionState.setPreferRemote(true)
        #expect(await AntigravitySessionState.preferRemote() == true)

        let strategyIDs = await self.strategyIDs(sourceMode: .auto)

        #expect(strategyIDs == ["antigravity.api", "antigravity.local"])
    }

    @Test
    func `explicit cli source ignores remote preference and resolves only local`() async {
        await AntigravitySessionState.setPreferRemote(true)

        let strategyIDs = await self.strategyIDs(sourceMode: .cli)

        #expect(strategyIDs == ["antigravity.local"])
    }

    @Test
    func `explicit oauth source ignores remote preference and resolves only oauth`() async {
        await AntigravitySessionState.setPreferRemote(false)

        let strategyIDs = await self.strategyIDs(sourceMode: .oauth)

        #expect(strategyIDs == ["antigravity.api"])
    }
}
