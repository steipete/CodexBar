import Foundation
import Testing
@testable import CodexBarCore

struct IdentifiedCostCollectionTests {
    @Test
    func `validation encoding and merging run on the scan queue`() async throws {
        let fetcher = RemoteCodexCostFetcher { _, _ in
            """
            {"schemaVersion":1,"provider":"fixture","startUnixMs":1788134400000,
             "endUnixMs":1788177600000,"conflictingIDs":[],"excludedCount":0}
            """
        }
        let result = try await IdentifiedCostCollection.collect(
            remotes: ["fixture"],
            startUnixMs: 1_788_134_400_000,
            endUnixMs: 1_788_177_600_000,
            local: { ScanQueueLedger() },
            fetchRemote: { host in
                try await fetcher.fetchIdentifiedUsage(
                    host: host, historyDays: 1, startUnixMs: 1_788_134_400_000, endUnixMs: 1_788_177_600_000,
                    ledgerType: ScanQueueLedger.self, environment: [:])
            })
        #expect(result.allSourcesAvailable)
        #expect(result.subtotal?.requestCount == 0)
    }

    @Test(arguments: [Array(repeating: "fixture", count: 16), ["fixture", "host;command"]])
    func `rejects invalid destinations before scanning or invoking SSH`(hosts: [String]) async {
        await #expect(throws: RemoteCodexCostError.self) {
            try await IdentifiedCostCollection.collect(
                remotes: hosts,
                startUnixMs: 1_788_134_400_000,
                endUnixMs: 1_788_177_600_000,
                local: {
                    Issue.record("An invalid destination must prevent the local scan")
                    return CodexRequestLedger(startUnixMs: 1_788_134_400_000, endUnixMs: 1_788_177_600_000)
                },
                fetchRemote: { _ in
                    Issue.record("An invalid destination must prevent SSH")
                    return CodexRequestLedger(startUnixMs: 1_788_134_400_000, endUnixMs: 1_788_177_600_000)
                })
        }
    }
}

@_silgen_name("dispatch_queue_get_label")
private func currentQueueLabel(_ queue: OpaquePointer?) -> UnsafePointer<CChar>

private struct ScanQueueLedger: IdentifiedRequestLedger {
    static let providerName = "fixture"
    static let supportedSchemaVersion = 1
    var schemaVersion = 1
    var provider = "fixture"
    var startUnixMs: Int64 = 1_788_134_400_000
    var endUnixMs: Int64 = 1_788_177_600_000
    var conflictingIDs: [String] = []
    var excludedCount = 0

    private static var onScanQueue: Bool {
        String(cString: currentQueueLabel(nil)) == CostUsageScanExecutor.queueLabel
    }

    func validate(startUnixMs _: Int64, endUnixMs _: Int64) throws {
        guard Self.onScanQueue else { throw RemoteCodexCostError.invalidReport }
    }

    func encode(to encoder: any Encoder) throws {
        try self.validate(startUnixMs: self.startUnixMs, endUnixMs: self.endUnixMs)
        var container = encoder.singleValueContainer()
        try container.encode("fixture")
    }

    static func makeMerger() -> @Sendable ([Self]) throws -> CodexRequestSubtotal {
        let createdOnScanQueue = Self.onScanQueue
        return { _ in
            guard createdOnScanQueue, Self.onScanQueue else { throw RemoteCodexCostError.invalidReport }
            return .init(
                totalTokens: 0, requestCount: 0, conflictCount: 0, excludedCount: 0,
                partial: false, costUSD: 0, unpricedRequestCount: 0)
        }
    }
}
