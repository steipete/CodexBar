import CodexBarCore
import Foundation
import Testing

struct CodexPlanFormattingTests {
    @Test
    func `maps Codex pro plans to usage multiplier names`() {
        #expect(CodexPlanFormatting.displayName("pro") == "Pro 20x")
        #expect(CodexPlanFormatting.displayName("Pro") == "Pro 20x")
        #expect(CodexPlanFormatting.displayName("Codex Pro") == "Pro 20x")
        #expect(CodexPlanFormatting.displayName("prolite") == "Pro 5x")
        #expect(CodexPlanFormatting.displayName("pro_lite") == "Pro 5x")
        #expect(CodexPlanFormatting.displayName("pro-lite") == "Pro 5x")
        #expect(CodexPlanFormatting.displayName("Pro Lite") == "Pro 5x")
        #expect(CodexPlanFormatting.displayName("Codex Pro Lite") == "Pro 5x")
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
        #expect(CodexPlanFormatting.displayName("Enterprise") == "Enterprise")
    }
}
