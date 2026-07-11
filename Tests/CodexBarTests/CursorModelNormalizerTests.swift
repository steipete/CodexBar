import Testing
@testable import CodexBarCore

struct CursorModelNormalizerTests {
    @Test
    func `gpt extra high effort keeps the priced base key`() {
        let model = CursorModelNormalizer.normalize("gpt-5.5-extra-high")

        #expect(model.pricingKey == "gpt-5.5")
        #expect(model.effort == "extra-high")
        #expect(model.provider == .openai)
    }

    @Test
    func `provider prefixes do not change the normalized pricing key`() {
        let model = CursorModelNormalizer.normalize("openai/gpt-5.5-2026-04-23-high")

        #expect(model.pricingKey == "gpt-5.5")
        #expect(model.effort == "high")
    }

    @Test
    func `unknown model remains unavailable instead of borrowing a rate`() {
        let model = CursorModelNormalizer.normalize("unknown-future-model")

        #expect(model.pricingKey == nil)
        #expect(model.provider == .unknown)
    }
}
