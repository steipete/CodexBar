import Foundation
import Testing
@testable import CodexBarCore

struct CopilotCreditsSettingsTests {
    @Test
    func `parses a plain entitlement`() {
        #expect(CopilotCreditEntitlementParser.parse("3000") == 3000)
        #expect(CopilotCreditEntitlementParser.parse("  6000  ") == 6000)
        #expect(CopilotCreditEntitlementParser.parse("1500.5") == 1500.5)
    }

    @Test
    func `rejects blank non numeric and non positive values`() {
        #expect(CopilotCreditEntitlementParser.parse("") == nil)
        #expect(CopilotCreditEntitlementParser.parse("   ") == nil)
        #expect(CopilotCreditEntitlementParser.parse("abc") == nil)
        #expect(CopilotCreditEntitlementParser.parse("0") == nil)
        #expect(CopilotCreditEntitlementParser.parse("-100") == nil)
    }

    @Test
    func `rejects non finite values`() {
        // "inf"/"1e999" parse to .infinity, which would crash progress validation downstream.
        #expect(CopilotCreditEntitlementParser.parse("inf") == nil)
        #expect(CopilotCreditEntitlementParser.parse("infinity") == nil)
        #expect(CopilotCreditEntitlementParser.parse("1e999") == nil)
    }

    @Test
    func `settings snapshot carries credit configuration`() {
        let settings = ProviderSettingsSnapshot.CopilotProviderSettings(
            apiToken: "test-token-placeholder",
            orgCreditsEnabled: true,
            seatCreditEntitlement: 3000,
            orgCreditEntitlement: 6000)
        #expect(settings.orgCreditsEnabled)
        #expect(settings.seatCreditEntitlement == 3000)
        #expect(settings.orgCreditEntitlement == 6000)
    }

    @Test
    func `settings snapshot defaults credits off`() {
        let settings = ProviderSettingsSnapshot.CopilotProviderSettings(apiToken: "t")
        #expect(settings.orgCreditsEnabled == false)
        #expect(settings.seatCreditEntitlement == nil)
        #expect(settings.orgCreditEntitlement == nil)
    }

    @Test
    func `token account decoding defaults missing entitlements to nil`() throws {
        // Legacy accounts predate the per-account entitlement keys and must still decode.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "label": "Legacy",
          "token": "token",
          "addedAt": 0
        }
        """
        let account = try JSONDecoder().decode(ProviderTokenAccount.self, from: Data(json.utf8))
        #expect(account.seatCreditEntitlement == nil)
        #expect(account.orgCreditEntitlement == nil)
        #expect(account.sanitizedSeatCreditEntitlement == nil)
        #expect(account.sanitizedOrgCreditEntitlement == nil)
    }

    @Test
    func `token account entitlements survive a codable round trip`() throws {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Work",
            token: "token",
            addedAt: 0,
            lastUsed: nil,
            seatCreditEntitlement: "1500",
            orgCreditEntitlement: "2000")
        let decoded = try JSONDecoder().decode(ProviderTokenAccount.self, from: JSONEncoder().encode(account))
        #expect(decoded.seatCreditEntitlement == "1500")
        #expect(decoded.orgCreditEntitlement == "2000")
    }
}
