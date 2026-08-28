import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ProviderInstanceIDTests {
    @Test(arguments: ["a", "codex", "acme-gateway", String(repeating: "a", count: 64), "0-9"])
    func `accepts IDs from the declared ASCII grammar`(_ rawValue: String) throws {
        let instanceID = try #require(ProviderInstanceID(rawValue: rawValue))
        #expect(instanceID.rawValue == rawValue)
    }

    @Test(arguments: [
        "",
        "UPPERCASE",
        "under_score",
        "contains space",
        "café",
        "slash/value",
        String(repeating: "a", count: 65),
    ])
    func `rejects IDs outside the declared ASCII grammar`(_ rawValue: String) {
        #expect(ProviderInstanceID(rawValue: rawValue) == nil)
    }

    @Test
    func `codable representation is a validated bare string`() throws {
        let instanceID = try #require(ProviderInstanceID(rawValue: "acme-gateway"))
        let encoded = try JSONEncoder().encode(instanceID)

        #expect(String(data: encoded, encoding: .utf8) == #""acme-gateway""#)
        #expect(try JSONDecoder().decode(ProviderInstanceID.self, from: encoded) == instanceID)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProviderInstanceID.self, from: Data(#""Acme""#.utf8))
        }
    }

    @Test
    func `first party mapping preserves raw values and rejects dynamic IDs`() throws {
        for provider in UsageProvider.allCases {
            #expect(provider.instanceID.rawValue == provider.rawValue)
            #expect(provider.instanceID.firstPartyProvider == provider)
        }

        let dynamicID = try #require(ProviderInstanceID(rawValue: "acme-gateway"))
        #expect(dynamicID.firstPartyProvider == nil)
    }

    @Test
    func `distinct instance IDs isolate runtime state`() throws {
        let first = try #require(ProviderInstanceID(rawValue: "acme-primary"))
        let second = try #require(ProviderInstanceID(rawValue: "acme-secondary"))
        var snapshots: [ProviderInstanceID: String] = [:]
        var errors: [ProviderInstanceID: String] = [:]

        snapshots[first] = "first snapshot"
        snapshots[second] = "second snapshot"
        errors[first] = "first error"

        #expect(snapshots[first] == "first snapshot")
        #expect(snapshots[second] == "second snapshot")
        #expect(errors[first] == "first error")
        #expect(errors[second] == nil)
    }

    @Test
    func `distinct dynamic instances persist isolated history files`() throws {
        let first = try #require(ProviderInstanceID(rawValue: "acme-primary"))
        let second = try #require(ProviderInstanceID(rawValue: "acme-secondary"))
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderInstanceIDTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = PlanUtilizationHistoryStore(directoryURL: directoryURL)
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        func buckets(_ percent: Double) -> PlanUtilizationHistoryBuckets {
            PlanUtilizationHistoryBuckets(unscoped: [
                PlanUtilizationSeriesHistory(
                    name: .session,
                    windowMinutes: 300,
                    entries: [
                        PlanUtilizationHistoryEntry(
                            capturedAt: capturedAt,
                            usedPercent: percent,
                            resetsAt: nil),
                    ]),
            ])
        }

        store.save([first: buckets(20), second: buckets(80)])
        let loaded = store.load()

        #expect(loaded[first]?.unscoped.first?.entries.first?.usedPercent == 20)
        #expect(loaded[second]?.unscoped.first?.entries.first?.usedPercent == 80)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) == [
            "acme-primary.json",
            "acme-secondary.json",
        ])
    }
}
