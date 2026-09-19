import CodexBarCore
import Foundation
import Testing

struct OpenCodexRouteDispatcherTests {
    @Test(arguments: [
        ("openai", OpenCodexRouteTarget.subscription(.codex)),
        ("xai", OpenCodexRouteTarget.tokenOnly),
        ("  XAI\n", OpenCodexRouteTarget.tokenOnly),
        ("opencode-go", OpenCodexRouteTarget.subscription(.opencodego)),
        ("kimi-coding", OpenCodexRouteTarget.subscription(.kimi)),
        ("deepseek", OpenCodexRouteTarget.subscription(.deepseek)),
        ("opencode-free", OpenCodexRouteTarget.tokenOnly),
        ("kimi", OpenCodexRouteTarget.unknown),
        ("anthropic", OpenCodexRouteTarget.unknown),
        ("unknown", OpenCodexRouteTarget.unknown),
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

    @Test
    func `explicit xai model prefix stays token only without record time auth evidence`() {
        #expect(OpenCodexRouteDispatcher.route(modelName: "xai/grok-4.6") == .tokenOnly)
        #expect(
            OpenCodexRouteDispatcher.route(
                provider: "openai",
                modelName: "  xai/grok-4.6  ") == .tokenOnly)
    }
}
