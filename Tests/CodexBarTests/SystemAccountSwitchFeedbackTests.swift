import Testing
@testable import CodexBar
@testable import CodexBarCore

/// `.grok` and `.kilo` stand in for any provider: the feedback model is provider-agnostic.
struct SystemAccountSwitchFeedbackTests {
    @Test
    func `switching shows a loading subtitle for that account only`() {
        var feedback = SystemAccountSwitchFeedback()
        feedback.begin(provider: .grok, accountID: "7", label: "Account 7", cliName: "Grok CLI")
        #expect(feedback.isSwitching(.grok))
        #expect(feedback.subtitle(for: .grok, accountID: "7")
            == .init(text: "Switching Grok CLI to Account 7…", style: .loading))
        #expect(feedback.subtitle(for: .grok, accountID: "2") == nil)
        #expect(feedback.subtitle(for: .grok, accountID: nil)
            == .init(text: "Switching Grok CLI to Account 7…", style: .loading))
        #expect(feedback.notification(for: .grok) == nil)
    }

    @Test
    func `success shows info subtitle and a notification until the menu closes`() {
        var feedback = SystemAccountSwitchFeedback()
        feedback.begin(provider: .grok, accountID: "7", label: "Account 7", cliName: "Grok CLI")
        feedback.finish(provider: .grok, outcome: .succeeded)
        #expect(!feedback.isSwitching(.grok))
        #expect(feedback.subtitle(for: .grok, accountID: "7")
            == .init(text: "Account 7 is now the System account", style: .info))
        #expect(feedback.notification(for: .grok)
            == .init(title: "System account switched", body: "Grok CLI now uses Account 7"))
        feedback.menuDidClose()
        #expect(feedback.phase(for: .grok) == nil)
    }

    @Test
    func `failure persists across menu closes until the next switch`() {
        var feedback = SystemAccountSwitchFeedback()
        feedback.begin(provider: .grok, accountID: "7", label: "Account 7", cliName: "Grok CLI")
        feedback.finish(provider: .grok, outcome: .failed(title: "Could not switch system account", message: "Boom"))
        feedback.menuDidClose()
        #expect(feedback.subtitle(for: .grok, accountID: "7") == .init(text: "Boom", style: .error))
        #expect(feedback.notification(for: .grok) == .init(title: "Could not switch system account", body: "Boom"))
        feedback.begin(provider: .grok, accountID: "2", label: "Account 2", cliName: "Grok CLI")
        #expect(feedback.subtitle(for: .grok, accountID: "7") == nil)
    }

    @Test
    func `discarded outcome clears the phase without a notification`() {
        var feedback = SystemAccountSwitchFeedback()
        feedback.begin(provider: .grok, accountID: "7", label: "Account 7", cliName: "Grok CLI")
        feedback.finish(provider: .grok, outcome: .discarded)
        #expect(feedback.phase(for: .grok) == nil)
        #expect(feedback.notification(for: .grok) == nil)
    }

    @Test
    func `finish without a pending switch is ignored`() {
        var feedback = SystemAccountSwitchFeedback()
        feedback.finish(provider: .grok, outcome: .succeeded)
        #expect(feedback.phase(for: .grok) == nil)
    }

    @Test
    func `providers keep independent phases`() {
        var feedback = SystemAccountSwitchFeedback()
        feedback.begin(provider: .grok, accountID: "7", label: "Account 7", cliName: "Grok CLI")
        #expect(feedback.phase(for: .kilo) == nil)
        #expect(!feedback.isSwitching(.kilo))
    }
}
