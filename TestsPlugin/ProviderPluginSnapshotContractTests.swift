import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginSnapshotContractTests {
    @Test(arguments: ProviderPluginTransportTests.engines)
    func `explicit empty snapshots need no invented usage or identity`(engine: ProviderPluginEngineKind) async throws {
        for body in ["{ empty: true }", "{ empty: true, identity: { loginMethod: 'API' } }"] {
            let runtime = try ProviderPluginTransportTests.runtime(engine, body: "return \(body);")
            let usage = try await runtime.fetchUsage()
            #expect(usage.primary == nil)
            #expect(usage.secondary == nil)
            #expect(usage.tertiary == nil)
            #expect(usage.extraRateWindows == nil)
            #expect(usage.providerCost == nil)
            #expect(usage.details.isEmpty)
            #expect((usage.identity == nil) == (body == "{ empty: true }"))
            #expect(usage.identity?.providerID == (usage.identity == nil ? nil : .neuralwatt))
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `empty marker does not bypass snapshot validation`(engine: ProviderPluginEngineKind) async throws {
        for body in [
            "{}", "{ empty: false }", "{ empty: 'true' }", "{ empty: 1 }", "{ empty: null }",
            "{ empty: true, primary: { usedPercent: 'wrong' } }", "{ empty: true, identity: [] }",
        ] {
            let runtime = try ProviderPluginTransportTests.runtime(engine, body: "return \(body);")
            await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
        }
    }
}
