import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct GeminiPrimaryWindowTests {
    @Test
    func `flash-only account does not fabricate a phantom 0% primary window`() {
        let snapshot = GeminiStatusSnapshot(
            modelQuotas: [
                GeminiModelQuota(modelId: "gemini-2.5-flash", percentLeft: 5, resetTime: nil, resetDescription: nil),
                GeminiModelQuota(
                    modelId: "gemini-2.5-flash-lite", percentLeft: 60, resetTime: nil, resetDescription: nil),
            ],
            rawText: "",
            accountEmail: nil,
            accountPlan: nil)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 95)
        #expect(usage.tertiary?.usedPercent == 40)
    }

    @Test
    func `pro quota still populates the primary window`() {
        let snapshot = GeminiStatusSnapshot(
            modelQuotas: [
                GeminiModelQuota(modelId: "gemini-2.5-pro", percentLeft: 30, resetTime: nil, resetDescription: nil),
                GeminiModelQuota(modelId: "gemini-2.5-flash", percentLeft: 70, resetTime: nil, resetDescription: nil),
            ],
            rawText: "",
            accountEmail: nil,
            accountPlan: nil)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 70)
        #expect(usage.secondary?.usedPercent == 30)
    }
}
