import CodexBarCore
import Foundation
import Testing

struct CodexPlanFormattingTests {
    @Test
    func `formats Codex pro tiers without inferring an allowance`() {
        #expect(CodexPlanFormatting.displayName("pro") == "Pro")
        #expect(CodexPlanFormatting.displayName("Pro") == "Pro")
        #expect(CodexPlanFormatting.displayName("Codex Pro") == "Pro")
        #expect(CodexPlanFormatting.displayName("prolite") == "Pro Lite")
        #expect(CodexPlanFormatting.displayName("pro_lite") == "Pro Lite")
        #expect(CodexPlanFormatting.displayName("pro-lite") == "Pro Lite")
        #expect(CodexPlanFormatting.displayName("Pro Lite") == "Pro Lite")
        #expect(CodexPlanFormatting.displayName("Codex Pro Lite") == "Pro Lite")
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
    func `preserves unrelated already readable plan text`() {
        #expect(CodexPlanFormatting.displayName("Pro 5x") == "Pro 5x")
        #expect(CodexPlanFormatting.displayName("Pro 10x") == "Pro 10x")
        #expect(CodexPlanFormatting.displayName("Enterprise") == "Enterprise")
    }
}
