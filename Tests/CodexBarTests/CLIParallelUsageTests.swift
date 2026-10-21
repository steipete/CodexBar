import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIParallelUsageTests {
    @Test
    func `bounded provider fetching preserves output diagnostics and failure order`() async throws {
        let providers: [UsageProvider] = [.codex, .claude, .gemini, .cursor, .copilot, .kilo]
        let clock = ContinuousClock()
        let sequential = SlowProviders()
        let sequentialDiagnostics = CLIStderrBuffer()
        let start = clock.now
        let reference = await CodexBarCLI.$stderrBuffer.withValue(sequentialDiagnostics) {
            await ProviderInteractionContext.$current.withValue(.background) {
                var output = UsageCommandOutput()
                for provider in providers {
                    await output.merge(sequential.fetch(provider))
                }
                return output
            }
        }
        let sequentialDuration = start.duration(to: clock.now)
        let parallel = SlowProviders()
        let parallelDiagnostics = CLIStderrBuffer()
        let parallelStart = clock.now
        let result = await CodexBarCLI.$stderrBuffer.withValue(parallelDiagnostics) {
            await CodexBarCLI.collectUsageOutputs(providers: providers) {
                await parallel.fetch($0)
            }
        }
        let parallelDuration = parallelStart.duration(to: clock.now)

        #expect(await sequential.peak == 1)
        #expect(await parallel.peak == 3)
        #expect(result.sections == providers.map(\.rawValue))
        #expect(result.sections == reference.sections)
        #expect(result.payload.map(\.provider) == providers.map(\.rawValue))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(result.payload) == encoder.encode(reference.payload))
        #expect(parallelDiagnostics.contents == sequentialDiagnostics.contents)
        #expect(result.exitCode == .failure)
        #expect(result.exitCode == reference.exitCode)
        print("Synthetic six-provider fetch: sequential=\(sequentialDuration), bounded=\(parallelDuration), peak=3")
    }

    @Test
    func `empty and single provider collections complete without extra work`() async {
        let empty = await CodexBarCLI.collectUsageOutputs(providers: []) { _ in
            Issue.record("Empty selection fetched a provider")
            return UsageCommandOutput()
        }
        #expect(empty.sections.isEmpty)
        #expect(empty.exitCode == .success)
        let single = await ProviderInteractionContext.$current.withValue(.userInitiated) {
            await CodexBarCLI.collectUsageOutputs(providers: [.gemini]) { provider in
                #expect(ProviderInteractionContext.current == .background)
                return UsageCommandOutput(sections: [provider.rawValue])
            }
        }
        #expect(single.sections == ["gemini"])
    }

    private actor SlowProviders {
        private var active = 0
        private(set) var peak = 0

        func fetch(_ provider: UsageProvider) async -> UsageCommandOutput {
            self.active += 1
            self.peak = max(self.peak, self.active)
            #expect(ProviderInteractionContext.current == .background)
            CodexBarCLI.writeStderr("[\(provider.rawValue)] begin\n")
            try? await Task.sleep(for: .milliseconds(provider == .codex ? 100 : 30))
            CodexBarCLI.writeStderr("[\(provider.rawValue)] end\n")
            self.active -= 1
            let code: ExitCode = provider == .claude ? ExitCode(3) : provider == .kilo ? .failure : .success
            let payload = ProviderPayload(
                provider: provider,
                account: nil,
                version: nil,
                source: "synthetic",
                status: nil,
                usage: nil,
                credits: nil,
                antigravityPlanInfo: nil,
                openaiDashboard: nil,
                error: code == .success ? nil : ProviderErrorPayload(
                    code: code.rawValue,
                    message: "Synthetic failure",
                    kind: .provider))
            return UsageCommandOutput(sections: [provider.rawValue], payload: [payload], exitCode: code)
        }
    }
}
