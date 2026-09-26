import CodexBarCore
import Foundation
import Testing

struct OpenCodexRouteDispatcherTests {
    @Test(arguments: [
        ("openai", OpenCodexRouteTarget.subscription(.codex)),
        ("opencode-go", OpenCodexRouteTarget.subscription(.opencodego)),
        ("kimi-coding", OpenCodexRouteTarget.subscription(.kimi)),
        ("deepseek", OpenCodexRouteTarget.subscription(.deepseek)),
        ("nous", OpenCodexRouteTarget.subscription(.nous)),
        (" NOUS\n", OpenCodexRouteTarget.subscription(.nous)),
        ("opencode-free", OpenCodexRouteTarget.tokenOnly),
        ("unknown-vendor", OpenCodexRouteTarget.unknown),
    ])
    func `provider routes to the expected subscription target`(
        provider: String,
        expected: OpenCodexRouteTarget)
    {
        #expect(OpenCodexRouteDispatcher.route(provider: provider) == expected)
    }

    @Test(arguments: [
        ("gpt-5.6-sol", true),
        ("openai/gpt-5.6-sol", true),
        ("opencode-go/deepseek-v4-flash", false),
        ("kimi-coding/k2p5", false),
        ("nous/anthropic/claude-sonnet-4.6", false),
        ("/fixture-model", false),
        ("unknown-vendor/fixture-model", false),
    ])
    func `codex subscription attribution respects model route prefixes`(
        modelName: String,
        expected: Bool)
    {
        #expect(OpenCodexRouteDispatcher.countsTowardCodexSubscription(modelName: modelName) == expected)
    }

    @Test
    func `model prefix wins over a mismatched provider label`() {
        #expect(
            OpenCodexRouteDispatcher.route(
                provider: "openai",
                modelName: "opencode-go/deepseek-v4-flash") == .subscription(.opencodego))
        #expect(
            OpenCodexRouteDispatcher.route(
                provider: "opencode-go",
                modelName: "gpt-5.2") == .subscription(.opencodego))
    }

    @Test(arguments: ["anthropic/claude-sonnet-4.6", "deepseek/fixture-model", "openai/gpt-5.4"])
    func `Nous billing identity wins over the model vendor namespace`(model: String) {
        #expect(OpenCodexRouteDispatcher.route(provider: "nous", modelName: model) == .subscription(.nous))
        #expect(OpenCodexRouteDispatcher.route(provider: "unknown-vendor", modelName: model) == .unknown)
    }
}
