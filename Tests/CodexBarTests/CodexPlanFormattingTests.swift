import CodexBarCore
import Foundation
import Testing

struct CodexPlanFormattingTests {
    @Test
    func `maps prolite aliases to Pro Lite`() {
        #expect(CodexPlanFormatting.displayName("prolite") == "Pro Lite")
        #expect(CodexPlanFormatting.displayName("pro_lite") == "Pro Lite")
        #expect(CodexPlanFormatting.displayName("pro-lite") == "Pro Lite")
        #expect(CodexPlanFormatting.displayName("pro lite") == "Pro Lite")
    }

    @Test
    func `returns nil for empty plan values`() {
        #expect(CodexPlanFormatting.displayName(nil) == nil)
        #expect(CodexPlanFormatting.displayName("") == nil)
        #expect(CodexPlanFormatting.displayName("   ") == nil)
    }

    @Test
    func `humanizes machine style plan identifiers`() {
        #expect(
            CodexPlanFormatting.displayName("enterprise_cbp_usage_based")
                == "Enterprise CBP Usage Based")
        #expect(
            CodexPlanFormatting.displayName("self_serve_business_usage_based")
                == "Self Serve Business Usage Based")
        #expect(CodexPlanFormatting.displayName("k12") == "K12")
    }

    @Test
    func `preserves already readable plan text`() {
        #expect(CodexPlanFormatting.displayName("Enterprise") == "Enterprise")
        #expect(CodexPlanFormatting.displayName("Pro Lite") == "Pro Lite")
    }
}
