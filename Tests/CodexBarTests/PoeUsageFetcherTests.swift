import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct PoeUsageFetcherTests {
    @Test
    func `parse snapshot extracts current point balance`() throws {
        let json = #"{"current_point_balance": 1500}"#
        let data = Data(json.utf8)
        let snapshot = try PoeUsageFetcher._parseSnapshotForTesting(data)
        #expect(snapshot.currentPointBalance == 1500)
    }

    @Test
    func `parse snapshot accepts string-encoded balance`() throws {
        let json = #"{"current_point_balance": "2500"}"#
        let snapshot = try PoeUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.currentPointBalance == 2500)
    }

    @Test
    func `parse snapshot returns nil balance when absent`() throws {
        let json = #"{}"#
        let snapshot = try PoeUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.currentPointBalance == nil)
    }

    @Test
    func `parse snapshot throws on malformed JSON`() {
        #expect {
            _ = try PoeUsageFetcher._parseSnapshotForTesting(Data("not-json".utf8))
        } throws: { error in
            guard case PoeUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `snapshot maps balance to identity loginMethod only, not RateWindow`() {
        let snapshot = PoeUsageSnapshot(
            currentPointBalance: 500,
            updatedAt: Date())

        let unified = snapshot.toUsageSnapshot()
        // No rate windows — balance is not a usage percentage
        #expect(unified.primary == nil)
        #expect(unified.secondary == nil)
        #expect(unified.tertiary == nil)
        // Balance lives in identity.loginMethod as "Balance: X points"
        #expect(unified.identity?.providerID == .poe)
        #expect(unified.identity?.loginMethod == "Balance: 500 points")
    }

    @Test
    func `snapshot hides balance when balance is absent`() {
        let snapshot = PoeUsageSnapshot(
            currentPointBalance: nil,
            updatedAt: Date())

        let unified = snapshot.toUsageSnapshot()
        #expect(unified.primary == nil)
        #expect(unified.identity?.loginMethod == nil)
    }

    @Test
    func `missing credentials fetch call throws missing credentials`() async {
        do {
            _ = try await PoeUsageFetcher.fetchUsage(apiKey: "   ")
            Issue.record("Expected missingCredentials error")
        } catch let error as PoeUsageError {
            guard case .missingCredentials = error else {
                Issue.record("Expected .missingCredentials but got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `compact number formats thousands with no decimals`() {
        #expect(PoeUsageSnapshot.compactNumber(1500) == "1,500")
        #expect(PoeUsageSnapshot.compactNumber(999) == "999")
        #expect(PoeUsageSnapshot.compactNumber(10000) == "10,000")
    }
}
