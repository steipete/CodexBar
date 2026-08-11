import Testing
@testable import CodexBar

#if canImport(JavaScriptCore)
struct UserPluginQuotaPresentationTests {
    @Test
    func `remaining mode aligns plugin label and bar`() {
        let presentation = UserPluginQuotaPresentation.make(usedPercent: 4, showUsed: false)

        #expect(presentation.percent == 96)
        #expect(presentation.text == "96% left")
    }

    @Test
    func `used mode aligns plugin label and bar`() {
        let presentation = UserPluginQuotaPresentation.make(usedPercent: 4, showUsed: true)

        #expect(presentation.percent == 4)
        #expect(presentation.text == "4% used")
    }

    @Test
    func `plugin percentage is clamped before presentation`() {
        #expect(UserPluginQuotaPresentation.make(usedPercent: -5, showUsed: true).percent == 0)
        #expect(UserPluginQuotaPresentation.make(usedPercent: 105, showUsed: false).percent == 0)
    }
}
#endif
