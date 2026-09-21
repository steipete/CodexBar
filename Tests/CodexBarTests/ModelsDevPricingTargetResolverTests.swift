import Testing
@testable import CodexBarCore

struct ModelsDevPricingTargetResolverTests {
    @Test
    func `direct provider preserves bare model identity and trims whitespace`() {
        #expect(Self.targets("  x-ai  ", "  Grok-4.6  ") == [
            Self.target("xai", "Grok-4.6"),
        ])
    }

    @Test
    func `direct provider strips one matching outer model prefix`() {
        #expect(Self.targets("OpenAI", "openai/GPT-5") == [Self.target("openai", "GPT-5")])
        #expect(Self.targets("x-ai", "x-ai/grok-4.6") == [Self.target("xai", "grok-4.6")])
        #expect(Self.targets("xai", "xai/xai/grok-4.6") == [Self.target("xai", "xai/grok-4.6")])
    }

    @Test
    func `openrouter preserves nested model namespace and strips only its outer prefix`() {
        #expect(Self.targets("openrouter", "openai/gpt-5") == [Self.target("openrouter", "openai/gpt-5")])
        #expect(Self.targets("OpenRouter", "openrouter/openai/gpt-5") == [Self.target("openrouter", "openai/gpt-5")])
    }

    @Test
    func `aliases retain exact provider before documented fallback`() {
        #expect(Self.targets("kimi-coding", "kimi-coding/k3") == [
            Self.target("kimi-coding", "k3"),
            Self.target("kimi-for-coding", "k3"),
        ])
        #expect(Self.targets("opencode-free", "opencode-free/opencode") == [
            Self.target("opencode-free", "opencode"),
            Self.target("opencode", "opencode"),
        ])
    }

    @Test
    func `google vertex retains its observed scope and unknown providers stay exact`() {
        #expect(Self.targets("google-vertex", "google-vertex/gemini-2.5-pro") == [
            Self.target("google-vertex", "gemini-2.5-pro"),
        ])
        #expect(Self.targets("private-proxy", "openai/gpt-5") == [
            Self.target("private-proxy", "openai/gpt-5"),
        ])
    }

    @Test
    func `empty and malformed model identities yield no targets`() {
        for (providerID, modelID) in [
            ("", "gpt-5"),
            ("openai", ""),
            ("openai", " / "),
            ("openai", "/gpt-5"),
            ("openai", "gpt-5/"),
        ] {
            #expect(Self.targets(providerID, modelID).isEmpty)
        }
    }

    private static func targets(_ providerID: String, _ modelID: String) -> [ModelsDevPricingTarget] {
        ModelsDevPricingTargetResolver.targets(providerID: providerID, modelID: modelID)
    }

    private static func target(_ providerID: String, _ modelID: String) -> ModelsDevPricingTarget {
        ModelsDevPricingTarget(providerID: providerID, modelID: modelID)
    }
}
