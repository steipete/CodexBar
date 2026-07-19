import AppKit
import CoreGraphics
import Testing
@testable import CodexBar

@MainActor
struct ProviderSwitcherEventPeekGateTests {
    @Test
    func `first check always peeks`() {
        let gate = ProviderSwitcherEventPeekGate(eventTypes: [.keyDown], counterProvider: { _ in 7 })
        #expect(gate.shouldPeek())
    }

    @Test
    func `unchanged counters skip the peek`() {
        let gate = ProviderSwitcherEventPeekGate(eventTypes: [.keyDown, .leftMouseDown], counterProvider: { _ in 7 })
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(!gate.shouldPeek())
        #expect(!gate.shouldPeek())
    }

    @Test
    func `any advanced counter re-enables the peek`() {
        var keyDownCount: UInt32 = 1
        let gate = ProviderSwitcherEventPeekGate(
            eventTypes: [.keyDown, .leftMouseDown],
            counterProvider: { type in type == .keyDown ? keyDownCount : 3 })
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(!gate.shouldPeek())
        keyDownCount += 1
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(!gate.shouldPeek())
    }

    @Test
    func `counter change keeps one follow up peek for AppKit queue delivery`() {
        var keyDownCount: UInt32 = 1
        let gate = ProviderSwitcherEventPeekGate(
            eventTypes: [.keyDown],
            counterProvider: { _ in keyDownCount })
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(!gate.shouldPeek())

        keyDownCount += 1
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(!gate.shouldPeek())
    }

    @Test
    func `queued unhandled event burst keeps peeking until the queue is empty`() throws {
        var eventCount: UInt32 = 1
        let gate = ProviderSwitcherEventPeekGate(
            eventTypes: [.keyUp],
            counterProvider: { _ in eventCount })
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(!gate.shouldPeek())

        eventCount += 3
        #expect(gate.shouldPeek())
        try gate.observe(Self.keyEvent(type: .keyUp, keyCode: 124))
        #expect(gate.shouldPeek())
        try gate.observe(Self.keyEvent(type: .keyUp, keyCode: 124))
        #expect(gate.shouldPeek())
        try gate.observe(Self.keyEvent(type: .keyUp, keyCode: 124))
        #expect(gate.shouldPeek())

        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(!gate.shouldPeek())
    }

    @Test
    func `handled event keeps peeking for delayed sibling from same counter snapshot`() throws {
        var eventCount: UInt32 = 1
        let gate = ProviderSwitcherEventPeekGate(
            eventTypes: [.keyUp],
            counterProvider: { _ in eventCount })
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(!gate.shouldPeek())

        eventCount += 2
        #expect(gate.shouldPeek())
        try gate.observe(Self.keyEvent(type: .keyUp, keyCode: 124))
        gate.observeQueueEmpty(afterFindingEvent: true)

        #expect(gate.shouldPeek())
        try gate.observe(Self.keyEvent(type: .keyUp, keyCode: 124))
        gate.observeQueueEmpty(afterFindingEvent: true)

        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(!gate.shouldPeek())
    }

    @Test
    func `held key keeps peeking for uncounted autorepeat events`() throws {
        let gate = ProviderSwitcherEventPeekGate(eventTypes: [.keyDown, .keyUp], counterProvider: { _ in 7 })
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(!gate.shouldPeek())

        try gate.observe(Self.keyEvent(type: .keyDown, keyCode: 124))
        #expect(gate.shouldPeek())
        #expect(gate.shouldPeek())

        try gate.observe(Self.keyEvent(type: .keyUp, keyCode: 124))
        #expect(gate.shouldPeek())
        gate.observeQueueEmpty(afterFindingEvent: false)
        #expect(!gate.shouldPeek())
    }

    private static func keyEvent(type: NSEvent.EventType, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode))
    }
}
