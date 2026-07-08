import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Guards the JSON contract the CodexBar iPhone app decodes (`ios/Shared/Transport/SyncEnvelope.swift`
/// + `ios/Shared/Model/WidgetSnapshot.swift`). If the macOS encoder drifts, the phone silently stops
/// syncing — these tests fail first.
struct MobileSyncEnvelopeTests {
    private func sampleSnapshot() -> WidgetSnapshot {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: RateWindow(usedPercent: 32, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 66, windowMinutes: 10_080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            usageRows: [
                .init(id: "primary", title: "Session", percentLeft: 68),
                .init(id: "secondary", title: "Weekly", percentLeft: 34),
            ],
            creditsRemaining: 42,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        return WidgetSnapshot(
            entries: [entry],
            enabledProviders: [.codex],
            usageBarsShowUsed: false,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_500))
    }

    @Test
    func `envelope encodes the fields the iPhone decoder requires`() throws {
        let envelope = MobileSyncEnvelope(snapshot: self.sampleSnapshot(), senderDeviceName: "Test Mac")
        let json = try JSONSerialization.jsonObject(with: envelope.encoded()) as? [String: Any]
        let root = try #require(json)

        #expect(root["schemaVersion"] as? Int == 1)
        #expect(root["senderDeviceName"] as? String == "Test Mac")

        let snapshot = try #require(root["snapshot"] as? [String: Any])
        #expect(snapshot["usageBarsShowUsed"] as? Bool == false)
        #expect(snapshot["enabledProviders"] as? [String] == ["codex"])
        // ISO8601 date encoding is part of the contract.
        #expect((snapshot["generatedAt"] as? String)?.contains("T") == true)

        let entries = try #require(snapshot["entries"] as? [[String: Any]])
        let first = try #require(entries.first)
        #expect(first["provider"] as? String == "codex")
        #expect(first["creditsRemaining"] as? Double == 42)

        let rows = try #require(first["usageRows"] as? [[String: Any]])
        #expect(rows.first?["id"] as? String == "primary")
        #expect(rows.first?["title"] as? String == "Session")
        #expect(rows.first?["percentLeft"] as? Double == 68)

        let primary = try #require(first["primary"] as? [String: Any])
        #expect(primary["usedPercent"] as? Double == 32)
    }

    @Test
    func `envelope JSON round-trips back into a WidgetSnapshot`() throws {
        let envelope = MobileSyncEnvelope(snapshot: self.sampleSnapshot(), senderDeviceName: "Test Mac")
        let data = try envelope.encoded()

        // Decode just the snapshot payload the way the iPhone would.
        struct DecodeEnvelope: Decodable {
            let schemaVersion: Int
            let senderDeviceName: String
            let snapshot: WidgetSnapshot
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DecodeEnvelope.self, from: data)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.snapshot.entries.count == 1)
        #expect(decoded.snapshot.entries.first?.provider == .codex)
        #expect(decoded.snapshot.entries.first?.usageRows?.count == 2)
    }
}
