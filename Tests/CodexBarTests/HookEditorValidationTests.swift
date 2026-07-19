import CodexBarCore
import Testing
@testable import CodexBar

struct HookEditorValidationTests {
    @Test
    func `rule creation stops at runtime limit`() {
        #expect(HookEditorValidation.canAddRule(count: HooksConfig.maximumRuleCount - 1))
        #expect(!HookEditorValidation.canAddRule(count: HooksConfig.maximumRuleCount))
    }

    @Test
    func `argument creation stops at runtime limit`() {
        #expect(HookEditorValidation.canAddArgument(count: HookRule.maximumArgumentCount - 1))
        #expect(!HookEditorValidation.canAddArgument(count: HookRule.maximumArgumentCount))
    }

    @Test
    func `quota threshold stays in runtime valid range`() {
        #expect(HookEditorValidation.thresholdFraction(percent: nil) == nil)
        #expect(HookEditorValidation.thresholdFraction(percent: 0) == 0.01)
        #expect(HookEditorValidation.thresholdFraction(percent: -5) == 0.01)
        #expect(HookEditorValidation.thresholdFraction(percent: 50) == 0.5)
        #expect(HookEditorValidation.thresholdFraction(percent: 120) == 1)
    }
}
