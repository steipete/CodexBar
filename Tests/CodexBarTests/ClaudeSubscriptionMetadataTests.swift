import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSubscriptionMetadataTests {
    private func response(
        status: String = "active",
        renewal: Any = "2026-11-05T14:15:04Z",
        renewalDay: Any = "2026-11-05",
        end: Any = NSNull(),
        endDay: Any = NSNull()) throws -> Data
    {
        try JSONSerialization.data(withJSONObject: [
            "status": status, "next_charge_at": renewal, "next_charge_date": renewalDay,
            "plan_ending_at": end, "plan_ending_before": endDay,
        ])
    }

    @Test(arguments: ["active", "trialing"])
    func `renewal keeps timestamp precision`(_ status: String) throws {
        let metadata = try ClaudeSubscriptionMetadata.parse(self.response(status: status))
        #expect(metadata.renews?.date == ISO8601DateFormatter().date(from: "2026-11-05T14:15:04Z"))
        #expect(metadata.renews?.isDateOnly == false)
        #expect(metadata.expires == nil)
    }

    @Test(arguments: ["active", "canceled"])
    func `scheduled ending overrides renewal and preserves calendar precision`(_ status: String) throws {
        let metadata = try ClaudeSubscriptionMetadata.parse(self.response(status: status, endDay: "2026-11-05"))
        #expect(metadata.renews == nil)
        #expect(metadata.expires?.date == ISO8601DateFormatter().date(from: "2026-11-05T00:00:00Z"))
        #expect(metadata.expires?.isDateOnly == true)
        let exact = try ClaudeSubscriptionMetadata.parse(self.response(
            end: "2026-11-05T14:15:04.123Z", endDay: "2026-11-06"))
        #expect(exact.expires?.isDateOnly == false)
        #expect(exact.expires?.date == ISO8601DateParser.parse("2026-11-05T14:15:04.123Z"))
    }

    @Test func `canceled subscription never infers renewal from stale next charge`() throws {
        let metadata = try ClaudeSubscriptionMetadata.parse(self.response(status: "canceled"))
        #expect(metadata.renews == nil && metadata.expires == nil)
    }

    @Test func `explicit empty clears dates without replacing quota or identity`() throws {
        let metadata = try ClaudeSubscriptionMetadata.parse(self.response(
            status: "canceled", renewal: NSNull(), renewalDay: NSNull()))
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 67, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            subscriptionRenewsAt: Date(),
            updatedAt: Date(timeIntervalSince1970: 100),
            identity: .init(
                providerID: .claude,
                accountEmail: "fixture@example.com",
                accountOrganization: "Fixture",
                loginMethod: "Claude Pro"))
        let cleared = metadata.applying(to: snapshot)
        #expect(cleared.subscriptionRenewsAt == nil && cleared.subscriptionExpiresAt == nil)
        #expect(cleared.primary?.usedPercent == 67)
        #expect(cleared.updatedAt == snapshot.updatedAt)
        #expect(cleared.identity?.accountEmail == snapshot.identity?.accountEmail)
    }

    @Test(arguments: ["2026-02-30", "2026-2-03", "not-a-date", ""])
    func `invalid calendar dates are unavailable`(_ value: String) throws {
        #expect(throws: ClaudeSubscriptionMetadata.ParseError.self) {
            try ClaudeSubscriptionMetadata.parse(self.response(endDay: value))
        }
    }

    @Test func `unknown or partial schema is not authoritative empty`() throws {
        for data in try [Data("{}".utf8), self.response(status: "unknown"), self.response(end: 123)] {
            #expect(throws: ClaudeSubscriptionMetadata.ParseError.self) {
                try ClaudeSubscriptionMetadata.parse(data)
            }
        }
    }

    @Test func `date precision survives snapshot replacement serialization and older JSON`() throws {
        let metadata = try ClaudeSubscriptionMetadata.parse(self.response(endDay: "2026-11-05"))
        let snapshot = metadata.applying(to: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundtrip = try decoder.decode(UsageSnapshot.self, from: encoder.encode(snapshot))
        #expect(roundtrip.subscriptionExpiresAtIsDateOnly)
        #expect(roundtrip.with(primary: nil, secondary: nil).subscriptionExpiresAtIsDateOnly)
        #expect(!roundtrip.withSubscriptionMetadata(expiresAt: nil, renewsAt: nil).subscriptionExpiresAtIsDateOnly)
        let old = try decoder.decode(UsageSnapshot.self, from: Data(#"{"updatedAt":"2026-11-05T00:00:00Z"}"#.utf8))
        #expect(!old.subscriptionExpiresAtIsDateOnly && !old.subscriptionRenewsAtIsDateOnly)
    }
}
