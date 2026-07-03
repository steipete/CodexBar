import Testing
@testable import CodexBar

struct QuotaWarningAlertPresentationStateTests {
    @Test
    func `replacement alert ignores stale dismissal`() {
        var state = QuotaWarningAlertPresentationState()
        let session = state.present(title: "Session quota low", message: "20% left")
        let weekly = state.present(title: "Weekly quota low", message: "10% left")

        #expect(state.dismiss(generation: session.generation) == false)
        #expect(state.current == weekly)
        #expect(state.dismiss(generation: weekly.generation) == true)
        #expect(state.current == nil)
    }

    @Test
    func `manual dismissal clears current alert`() {
        var state = QuotaWarningAlertPresentationState()
        state.present(title: "Session quota low", message: "20% left")

        state.dismiss()

        #expect(state.current == nil)
    }
}
