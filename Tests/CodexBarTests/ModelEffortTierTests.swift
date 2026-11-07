import CodexBarCore
import Testing

struct ModelEffortTierTests {
    @Test(arguments: [
        ("claude-opus-4-1", ModelEffortTier.high),
        ("anthropic.claude-opus-4-1", .high),
        ("gpt-5.1-codex-max", .high),
        ("gpt-5-pro", .high),
        ("gemini-2.5-pro", .high),
        ("o3", .high),
        ("o1", .high),
        ("claude-sonnet-4-5", .standard),
        ("gpt-5", .standard),
        ("gpt-5-codex", .standard),
        ("deepseek-chat", .standard),
        ("claude-haiku-4-5", .fast),
        ("gpt-5-mini", .fast),
        ("gpt-5-codex-mini", .fast),
        ("o4-mini", .fast),
        ("o4-mini-high", .fast),
        ("gemini-2.5-flash-lite", .fast),
        ("cursor-small", .fast),
    ])
    func `classifies public model ids`(name: String, tier: ModelEffortTier) {
        #expect(ModelEffortTier.classify(name) == tier)
    }

    @Test
    func `words match whole tokens only`() {
        // "o3" inside a longer token, "pro" inside "prompt", and "max" inside "maximal" are not tier words.
        #expect(ModelEffortTier.classify("go3-chat") == .standard)
        #expect(ModelEffortTier.classify("prompt-guard") == .standard)
        #expect(ModelEffortTier.classify("maximal-v1") == .standard)
    }
}
