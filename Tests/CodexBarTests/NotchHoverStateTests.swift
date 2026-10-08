import Testing
@testable import CodexBar

struct NotchHoverStateTests {
    @Test
    func `entering content before leaving the trigger preserves hover ownership`() {
        var state = NotchHoverState()
        #expect(state.update(.trigger, isInside: true) == .entered)
        #expect(state.update(.content, isInside: true) == .unchanged)
        #expect(state.update(.trigger, isInside: false) == .unchanged)
        #expect(state.isInside)
        #expect(state.update(.content, isInside: false) == .exited)
        #expect(!state.isInside)
    }

    @Test
    func `entering the next window after an exit cancels the hover grace period`() {
        var state = NotchHoverState()
        #expect(state.update(.trigger, isInside: true) == .entered)
        #expect(state.update(.trigger, isInside: false) == .exited)
        #expect(state.update(.content, isInside: true) == .entered)
        #expect(state.update(.trigger, isInside: true) == .unchanged)
        #expect(state.update(.content, isInside: false) == .unchanged)
        #expect(state.isInside)
    }

    @Test
    func `duplicate callbacks do not restart dwell or collapse grace`() {
        var state = NotchHoverState()
        #expect(state.update(.content, isInside: false) == .unchanged)
        #expect(state.update(.trigger, isInside: true) == .entered)
        #expect(state.update(.trigger, isInside: true) == .unchanged)
        #expect(state.update(.content, isInside: false) == .unchanged)
        #expect(state.update(.trigger, isInside: false) == .exited)
        #expect(state.update(.trigger, isInside: false) == .unchanged)
    }

    @Test
    func `hiding content leaves any trigger hover intact`() {
        var state = NotchHoverState()
        state.update(.trigger, isInside: true)
        state.update(.content, isInside: true)
        #expect(state.update(.content, isInside: false) == .unchanged)
        #expect(state.isInside)
        #expect(state.update(.trigger, isInside: false) == .exited)
    }

    @Test
    func `teardown clears both regions and ignores their late exit callbacks`() {
        var state = NotchHoverState()
        state.update(.trigger, isInside: true)
        state.update(.content, isInside: true)
        state.clear()
        #expect(!state.isInside)
        #expect(state.update(.trigger, isInside: false) == .unchanged)
        #expect(state.update(.content, isInside: false) == .unchanged)
        #expect(state.update(.trigger, isInside: true) == .entered)
    }
}
