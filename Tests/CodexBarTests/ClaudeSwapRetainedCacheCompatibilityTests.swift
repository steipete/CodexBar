import Foundation
import Testing
@testable import CodexBarCore

/// The retained-usage cache gained a provenance field, and CodexBar upgrades in
/// place over an existing file. These cover both directions of that change: a
/// payload written by an older build must still load, and the new field must
/// survive the round-trip rather than being laundered back into live data.
struct ClaudeSwapRetainedCacheCompatibilityTests {
    /// `JSONDecoder` defaults to `.deferredToDate`, so the fixture below stores
    /// this instant as seconds since the 2001 reference date, not since 1970.
    private let updatedAt = Date(timeIntervalSinceReferenceDate: 803_851_200)

    /// Exactly the shape an older build wrote: no `usesLastKnownUsage` key.
    private var legacyPayload: Data {
        Data("""
        [{
          "opaqueID": "1",
          "accountFingerprint": "abc123",
          "primary": {"usedPercent": 42, "resetsAt": null},
          "updatedAt": 803851200
        }]
        """.utf8)
    }

    @Test
    func `a cache written before the provenance field still loads`() throws {
        let account = try #require(ClaudeSwapRetainedUsageStore.decode(self.legacyPayload).first)

        #expect(account.id.opaqueID == "1")
        #expect(account.snapshot?.primary?.usedPercent == 42)
        #expect(account.snapshot?.updatedAt == self.updatedAt)
    }

    @Test
    func `a record predating the fallback decodes as live, not last known`() throws {
        let account = try #require(ClaudeSwapRetainedUsageStore.decode(self.legacyPayload).first)

        // Payloads without the key predate the fallback entirely, so every
        // record in them was a live measurement. Defaulting to true instead
        // would hide a real snapshot from the menu bar after an upgrade.
        #expect(account.usesLastKnownUsage == false)
    }

    @Test
    func `last known provenance survives the disk round trip`() throws {
        let data = try #require(ClaudeSwapRetainedUsageStore.encode([self.account(usesLastKnownUsage: true)]))
        let decoded = try #require(ClaudeSwapRetainedUsageStore.decode(data).first)

        #expect(decoded.usesLastKnownUsage, "a relaunch must not promote a retained fallback to live data")
        #expect(decoded.snapshot?.primary?.usedPercent == 71)
    }

    @Test
    func `a live record round trips without acquiring fallback provenance`() throws {
        let data = try #require(ClaudeSwapRetainedUsageStore.encode([self.account(usesLastKnownUsage: false)]))
        let decoded = try #require(ClaudeSwapRetainedUsageStore.decode(data).first)

        #expect(decoded.usesLastKnownUsage == false)
    }

    /// A live record must not start writing the key, so a cache written by this
    /// build stays readable by an older one rather than failing to decode.
    @Test
    func `a live record omits the provenance key entirely`() throws {
        let data = try #require(ClaudeSwapRetainedUsageStore.encode([self.account(usesLastKnownUsage: false)]))
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(!text.contains("usesLastKnownUsage"))
    }

    private func account(usesLastKnownUsage: Bool) -> ProviderAccountUsageSnapshot {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(
                source: ClaudeSwapAccountProjection.sourceName,
                opaqueID: "1"),
            provider: .claude,
            displayLabel: "a@b.c",
            accountEmail: "a@b.c",
            isActive: false,
            usesLastKnownUsage: usesLastKnownUsage,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 71, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: self.updatedAt,
                identity: nil),
            error: nil,
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel)
    }
}
