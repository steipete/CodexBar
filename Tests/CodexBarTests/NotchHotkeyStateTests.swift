import Foundation
import Testing
@testable import CodexBar

struct NotchHotkeyStateTests {
    @Test
    func `toggle mode alternates and never collapses on release`() {
        var state = NotchHotkeyState()

        #expect(state.press(mode: .toggle, isExpanded: false) == .expand)
        #expect(state.isHolding)
        // Release must not close a toggled-open panel.
        #expect(state.release(mode: .toggle, isPointerInside: false) == .ignore)
        #expect(state.isHolding)

        #expect(state.press(mode: .toggle, isExpanded: true) == .collapse)
        #expect(!state.isHolding)
    }

    @Test
    func `hold mode shows while held and closes on release`() {
        var state = NotchHotkeyState()

        #expect(state.press(mode: .hold, isExpanded: false) == .expand)
        #expect(state.isHolding)
        #expect(state.release(mode: .hold, isPointerInside: false) == .collapse)
        #expect(!state.isHolding)
    }

    @Test
    func `holding over the panel hands control back to hover`() {
        var state = NotchHotkeyState()

        _ = state.press(mode: .hold, isExpanded: false)
        #expect(state.release(mode: .hold, isPointerInside: true) == .ignore)
        #expect(!state.isHolding)
    }

    @Test
    func `pressing hold while already open keeps it open`() {
        var state = NotchHotkeyState()

        #expect(state.press(mode: .hold, isExpanded: true) == .expand)
        #expect(state.isHolding)
    }

    @Test
    func `release without a prior press is ignored`() {
        var state = NotchHotkeyState()

        #expect(state.release(mode: .hold, isPointerInside: false) == .ignore)
        #expect(state.release(mode: .toggle, isPointerInside: false) == .ignore)
    }

    @Test
    func `clear drops hold ownership so hover can collapse again`() {
        var state = NotchHotkeyState()

        _ = state.press(mode: .toggle, isExpanded: false)
        state.clear()
        #expect(!state.isHolding)
    }
}
