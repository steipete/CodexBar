import Foundation
import Testing
@testable import CodexBarCore

struct IdentifiedCostCollectionTests {
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
