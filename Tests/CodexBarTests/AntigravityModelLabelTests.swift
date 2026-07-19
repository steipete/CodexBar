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
}
