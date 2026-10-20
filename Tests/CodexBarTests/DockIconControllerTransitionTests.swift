import AppKit
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct DockIconControllerTransitionTests {
    @Test
    func `update passes never rescan application windows`() async throws {
        let controller = DockIconController()
        var scans = 0
        controller.windowProvider = {
            scans += 1
            return []
        }
        controller.start()
        try await self.drain(controller)
        let initialScans = scans

        for _ in 0..<50 {
            NotificationCenter.default.post(name: NSApplication.didUpdateNotification, object: nil)
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: nil)
        }
        #expect(!controller.isReevaluationScheduled)
        try await self.drain(controller)
        #expect(scans == initialScans)
    }

    @Test
    func `startup and window transitions coalesce without polling`() async throws {
        let controller = DockIconController()
        var scans = 0
        controller.windowProvider = {
            scans += 1
            return []
        }
        controller.start()
        controller.start()
        try await self.drain(controller)
        #expect(scans == 1)

        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ] {
            let before = scans
            NotificationCenter.default.post(name: name, object: nil)
            NotificationCenter.default.post(name: name, object: nil)
            #expect(controller.isReevaluationScheduled)
            try await self.drain(controller)
            #expect(scans == before + 1)
        }
    }

    private func drain(_ controller: DockIconController) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.isReevaluationScheduled, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!controller.isReevaluationScheduled)
    }
}
