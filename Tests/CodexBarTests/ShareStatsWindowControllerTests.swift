import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct ShareStatsWindowControllerTests {
    @Test(arguments: [10, 30])
    func `share preview is built once per update and released on close`(providerCount: Int) throws {
        _ = NSApplication.shared
        let payload = ShareStatsPayload(
            days: 30,
            periodEnd: Date(timeIntervalSince1970: 1_800_000_000),
            providers: (0..<providerCount).map { index in
                ShareStatsProviderPayload(
                    provider: .codex,
                    providerName: "Synthetic provider \(index)",
                    subscriptionName: nil,
                    currencyCode: "USD",
                    totalTokens: 100,
                    estimatedCost: 1,
                    coveredDayCount: 30)
            },
            topModels: [],
            currencies: [],
            totalTokens: providerCount * 100)
        let controller = ShareStatsWindowController(payload: payload)
        let window = try #require(controller.window)
        let presentedFrame = window.frameRect(forContentRect: NSRect(x: 100, y: 100, width: 820, height: 565))
        defer { controller.close() }
        // The presenter always supplies the current payload before showing the window.
        let initialPreviewCount = window.contentViewController == nil ? 0 : 1
        #expect(initialPreviewCount == 0)
        var retainedPreviewCount = 0
        for cycle in 0..<20 {
            weak var preview: NSViewController?
            weak var previewView: NSView?
            try autoreleasepool {
                controller.update(payload: payload)
                window.setFrame(presentedFrame, display: false)
                let installedPreview: NSViewController = try #require(window.contentViewController)
                preview = installedPreview
                previewView = preview?.view
                #expect(controller.payload == payload)
                if cycle == 0 {
                    controller.close()
                } else {
                    // An already closed offscreen window does not emit another native close event.
                    window.delegate?.windowWillClose?(Notification(
                        name: NSWindow.willCloseNotification,
                        object: window))
                }
            }
            if preview != nil || previewView != nil {
                retainedPreviewCount += 1
            }
        }
        #expect(retainedPreviewCount == 0)
        let remainingPreviewCount = window.contentViewController == nil ? 0 : 1
        #expect(remainingPreviewCount == 0)
        #expect(window.frame == presentedFrame)
    }
}
