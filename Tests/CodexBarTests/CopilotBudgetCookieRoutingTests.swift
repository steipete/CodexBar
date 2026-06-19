import Testing
@testable import CodexBarCore

struct CopilotBudgetCookieRoutingTests {
    @Test
    func `auto budget cookies ignore stale manual header`() {
        let settings = ProviderSettingsSnapshot.CopilotProviderSettings(
            budgetExtrasEnabled: true,
            budgetCookieSource: .auto,
            manualBudgetCookieHeader: "user_session=stale")

        #expect(CopilotAPIFetchStrategy.budgetCookieHeaderOverride(from: settings) == nil)
    }

    @Test
    func `manual budget cookies use trimmed manual header`() {
        let settings = ProviderSettingsSnapshot.CopilotProviderSettings(
            budgetExtrasEnabled: true,
            budgetCookieSource: .manual,
            manualBudgetCookieHeader: "  user_session=manual  ")

        #expect(CopilotAPIFetchStrategy.budgetCookieHeaderOverride(from: settings) == "user_session=manual")
    }

    @Test
    func `manual budget cookies require non-empty header`() {
        let settings = ProviderSettingsSnapshot.CopilotProviderSettings(
            budgetExtrasEnabled: true,
            budgetCookieSource: .manual,
            manualBudgetCookieHeader: "  ")

        #expect(CopilotAPIFetchStrategy.budgetCookieHeaderOverride(from: settings) == nil)
    }

    @Test
    func `invalid manual budget cookies do not fall back to browser import`() {
        let settings = ProviderSettingsSnapshot.CopilotProviderSettings(
            budgetExtrasEnabled: true,
            budgetCookieSource: .manual,
            manualBudgetCookieHeader: "Cookie:")

        #expect(CopilotAPIFetchStrategy.budgetCookieHeaderOverride(from: settings) == nil)
    }
}
