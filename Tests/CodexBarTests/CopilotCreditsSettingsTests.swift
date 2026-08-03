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
}
