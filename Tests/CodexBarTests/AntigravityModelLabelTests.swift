import Testing
@testable import CodexBarCore

struct AntigravityModelLabelTests {
    @Test
    func `humanizes raw model ids when label matches model id`() {
        #expect(AntigravityStatusSnapshot.humanizedModelID("gemini-3-pro-preview") == "Gemini 3 Pro Preview")
        #expect(AntigravityStatusSnapshot.humanizedModelID("gemini-2.5-flash") == "Gemini 2.5 Flash")
        #expect(AntigravityStatusSnapshot.humanizedModelID("example-3-1-pro-low") == "Example 3.1 Pro Low")
        #expect(AntigravityStatusSnapshot.humanizedModelID("gpt-api-oss") == "GPT API OSS")
        #expect(AntigravityStatusSnapshot.humanizedModelID("").isEmpty)
    }

    @Test
    func `preserves custom model labels`() {
        let quota = AntigravityModelQuota(
            label: "Custom enterprise label",
            modelId: "gemini-3-pro-preview",
            remainingFraction: 1,
            resetTime: nil,
            resetDescription: nil)

        #expect(AntigravityStatusSnapshot.quotaDisplayLabel(quota) == "Custom enterprise label")
    }

    @Test
    func `retired flash ids canonicalize to current flash`() {
        #expect(AntigravityStatusSnapshot.canonicalModelID("gemini-3.6-flash") == "gemini-3.7-flash")
        #expect(AntigravityStatusSnapshot.canonicalModelID("gemini-3.6-flash-high") == "gemini-3.7-flash")
        #expect(AntigravityStatusSnapshot.canonicalModelID("GEMINI-3.6-FLASH") == "gemini-3.7-flash")
        #expect(AntigravityStatusSnapshot.canonicalModelID("gemini-3.5-flash-mid") == "gemini-3.7-flash")
        #expect(AntigravityStatusSnapshot.canonicalModelID("gemini-3-flash-agent") == "gemini-3.7-flash")
        #expect(AntigravityStatusSnapshot.canonicalModelID("gemini-3.7-flash") == "gemini-3.7-flash")
        #expect(AntigravityStatusSnapshot.canonicalModelID("claude-sonnet-4-6") == "claude-sonnet-4-6")
    }

    @Test
    func `humanizes retired flash ids via canonical`() {
        #expect(AntigravityStatusSnapshot.humanizedModelID("gemini-3.6-flash-high") == "Gemini 3.7 Flash")
        #expect(AntigravityStatusSnapshot.quotaDisplayLabel(AntigravityModelQuota(
            label: "gemini-3.6-flash",
            modelId: "gemini-3.6-flash",
            remainingFraction: 0.5,
            resetTime: nil,
            resetDescription: nil)) == "Gemini 3.7 Flash")
    }
}
