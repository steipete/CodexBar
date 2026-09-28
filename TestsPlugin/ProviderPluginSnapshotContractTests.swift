import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginSnapshotContractTests {
    @Test(arguments: ProviderPluginTransportTests.engines)
    func `extra window knowledge preserves false and defaults to true`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
        return { extraWindows: [
          { id: 'unknown', title: 'Requests', usageKnown: false, window: { usedPercent: 0 } },
          { id: 'known', title: 'Tokens', usageKnown: true, usedPercent: 25 },
          { id: 'legacy', title: 'Budget', usedPercent: 50 }
        ] };
        """)
        let windows = try #require(try await runtime.fetchUsage().extraRateWindows)
        #expect(windows.map(\.usageKnown) == [false, true, true])
        #expect(windows.map(\.window.usedPercent) == [0, 25, 50])
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `detail ratios and raw usage retain numeric values`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
        return { details: [{ rows: [
          { label: 'Empty', value: '$0', progress: 0, usageValue: 0 },
          { label: 'Budget', value: '$25', progress: 0.25, usageValue: 25 },
          { label: 'Full', value: '$100', progress: 1, usageValue: 100 },
          { label: 'Legacy', value: 'No numeric data' }
        ] }] };
        """)
        let rows = try await runtime.fetchUsage().details[0].rows
        #expect(rows.map { $0.progress?.usedPercent } == [0, 25, 100, nil])
        #expect(rows.map(\.usageValue) == [0, 25, 100, nil])
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `snapshot numeric and knowledge fields reject invalid types and ranges`(
        engine: ProviderPluginEngineKind) async throws
    {
        for value in ["null", "0", "1", "'false'", "{}", "[]"] {
            let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
            return { extraWindows: [{ id: 'x', title: 'X', usedPercent: 0, usageKnown: \(value) }] };
            """)
            await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
        }
        for (key, values) in [
            ("progress", ["true", "'0.5'", "{}", "[]", "NaN", "Infinity", "-0.1", "1.1"]),
            ("usageValue", ["false", "'25'", "{}", "[]", "NaN", "Infinity"]),
        ] {
            for value in values {
                let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
                return { details: [{ rows: [{ label: 'Budget', value: '$25', \(key): \(value) }] }] };
                """)
                await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
            }
        }
    }

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

struct ProviderPluginOverQuotaTests {
    @Test(arguments: ProviderPluginTransportTests.engines)
    func `over quota values require an explicit manifest policy`(engine: ProviderPluginEngineKind) async throws {
        for (policy, expected) in [("", 100.0), ("snapshotPolicy: {percent: 'preserve-overage'},", 120.0)] {
            let runtime = try ProviderPluginRuntime(source: """
            defineProvider({id: 'notion', name: 'Fixture', settings: [], endpoints: ['https://example.test'],
              \(policy)
              async fetchUsage() { return {primary: {usedPercent: 120}, secondary: {usedPercent: -5},
                extraWindows: [{id: 'extra', title: 'Extra', usedPercent: 120}]}; }
            });
            """, engine: engine)
            let result = try await runtime.fetchUsage()
            #expect(result.primary?.usedPercent == expected)
            #expect(result.secondary?.usedPercent == 0)
            #expect(result.extraRateWindows?.first?.window.usedPercent == expected)
        }
    }
}
