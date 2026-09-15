import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CopilotStackedAllowanceTests {
    @Test(arguments: [false, true])
    func `stacked delayed outcomes preserve cleared inheritance and explicit allowances`(succeed: Bool) async throws {
        let fixture = CopilotAllowanceFixture()
        defer { fixture.stop() }
        fixture.settings.copilotSeatCreditEntitlementRaw = "3000"
        try fixture.seedAccounts()
        let receipt = try await CopilotStackedAllowanceProof.run(fixture: fixture, succeed: succeed)
        for (effect, correct) in receipt {
            #expect(correct, "\(effect)")
        }
    }
}

@MainActor
enum CopilotStackedAllowanceProof {
    static func run(fixture: CopilotAllowanceFixture, succeed: Bool) async throws -> [String: Bool] {
        fixture.settings.multiAccountMenuLayout = .stacked
        fixture.store.setCopilotSeatCreditEntitlement("")
        let before = try #require(fixture.store.accountSnapshots[.copilot])
        #expect(fixture.settings.copilotSeatCreditEntitlementRaw == "3000")
        #expect(before.first?.snapshot?.details.flatMap(\.rows).first?.progress?.total == 3000)
        #expect(before.first?.account.sanitizedSeatCreditEntitlement == nil)
        let gate = CopilotStackedResponseGate()
        let snapshots = Dictionary(uniqueKeysWithValues: before.compactMap { entry in
            entry.snapshot.map { (entry.account.token, $0) }
        })
        let strategy = CopilotStackedResponseStrategy(gate: gate, snapshots: snapshots, succeed: succeed)
        let spec = try #require(fixture.store.providerSpecs[.copilot])
        fixture.store.providerSpecs[.copilot] = ProviderSpec(
            style: spec.style,
            isEnabled: { true },
            descriptor: ProviderDescriptor(
                id: .copilot,
                metadata: spec.descriptor.metadata,
                branding: spec.descriptor.branding,
                tokenCost: spec.descriptor.tokenCost,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: [.auto, .api], pipeline: ProviderFetchPipeline { _ in [strategy] }),
                cli: spec.descriptor.cli),
            makeFetchContext: spec.makeFetchContext)
        let accounts = fixture.settings.tokenAccounts(for: .copilot)
        let refresh = Task { await fixture.store.refreshTokenAccounts(provider: .copilot, accounts: accounts) }
        while await !(gate.started) {
            await Task.yield()
        }
        let action = try #require(fixture.field?.actions.first { $0.id == "copilot-clear-default-allowance" })
        await action.perform()
        await gate.release()
        await refresh.value
        let cached = try #require(fixture.store.accountSnapshots[.copilot])
        var receipt: [String: Bool] = ["bothAccountsRetained": cached.count == 2]
        for (index, entry) in cached.enumerated() {
            let snapshot = try #require(entry.snapshot)
            let row = try #require(snapshot.details.flatMap(\.rows).first)
            receipt["account\(index)Allowance"] = row.progress?.total == (index == 0 ? nil : 9000)
            receipt["account\(index)Usage"] = row.usageValue == (index == 0 ? 123 : 456)
            receipt["account\(index)Timestamp"] = snapshot.updatedAt == before[index].snapshot?.updatedAt
                .addingTimeInterval(succeed ? 60 : 0)
        }
        for (label, snapshot) in [
            ("live", fixture.store.snapshots[.copilot]),
            ("reset", fixture.store.lastKnownResetSnapshots[.copilot]),
        ] {
            let row = try #require(snapshot?.details.flatMap(\.rows).first)
            receipt[label] = row.progress == nil && row.usageValue == 123
        }
        return receipt
    }
}

private actor CopilotStackedResponseGate {
    var started = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        self.started = true
        guard !self.released else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func release() {
        self.released = true
        self.waiters.forEach { $0.resume() }
        self.waiters.removeAll()
    }
}

private struct CopilotStackedResponseStrategy: ProviderFetchStrategy {
    let id = "copilot-stacked-fixture"
    let kind: ProviderFetchKind = .apiToken
    let gate: CopilotStackedResponseGate
    let snapshots: [String: UsageSnapshot]
    let succeed: Bool

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let token = try #require(context.settings?.copilot?.apiToken)
        let old = try #require(self.snapshots[token])
        await self.gate.wait()
        guard self.succeed else { throw URLError(.notConnectedToInternet) }
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: old.details,
            updatedAt: old.updatedAt.addingTimeInterval(60))
        return ProviderFetchResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "fixture",
            strategyID: self.id,
            strategyKind: self.kind)
    }
}
