import AppKit
import CodexBarCore
import SwiftUI

@MainActor
private final class DetachedPanelWindow: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

@MainActor
final class DetachedPanelController: NSWindowController, NSWindowDelegate {
    private static let cardWidth: CGFloat = 310
    private static let panelMargin: CGFloat = 8
    private static let defaultSize = NSSize(width: 330, height: 560)

    private let store: UsageStore
    private let settings: SettingsStore
    private let menuCardModelProvider: (UsageProvider?) -> UsageMenuCardView.Model?
    private let onClose: () -> Void

    init(
        store: UsageStore,
        settings: SettingsStore,
        menuCardModelProvider: @escaping (UsageProvider?) -> UsageMenuCardView.Model?,
        onClose: @escaping () -> Void)
    {
        self.store = store
        self.settings = settings
        self.menuCardModelProvider = menuCardModelProvider
        self.onClose = onClose
        super.init(window: nil)
        self.buildWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(anchoredTo statusButton: NSStatusBarButton?) {
        guard let panel = self.window else { return }
        self.positionPanel(panel, anchoredTo: statusButton)
        self.showWindow(nil)
        panel.orderFrontRegardless()
    }

    func bringToFront() {
        guard let panel = self.window else { return }
        self.showWindow(nil)
        panel.orderFrontRegardless()
    }

    private func buildWindow() {
        let panel = DetachedPanelWindow(
            contentRect: Self.defaultFrame(),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.title = "CodexBar"
        panel.titlebarAppearsTransparent = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let rootView = DetachedPanelContentView(
            store: self.store,
            settings: self.settings,
            panelWidth: Self.cardWidth,
            menuCardModelProvider: self.menuCardModelProvider,
            closePanel: { [weak self] in
                self?.close()
            })
        panel.contentView = NSHostingView(rootView: rootView)

        self.window = panel
    }

    private func positionPanel(_ panel: NSWindow, anchoredTo statusButton: NSStatusBarButton?) {
        guard let statusButton,
              let statusItemWindow = statusButton.window
        else {
            panel.center()
            return
        }

        let buttonFrameInWindow = statusButton.convert(statusButton.bounds, to: nil)
        let buttonFrameOnScreen = statusItemWindow.convertToScreen(buttonFrameInWindow)
        let screenFrame = statusItemWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: Self.defaultSize)

        var origin = NSPoint(
            x: buttonFrameOnScreen.midX - panel.frame.width / 2,
            y: buttonFrameOnScreen.minY - panel.frame.height - Self.panelMargin)
        let maxX = screenFrame.maxX - panel.frame.width - Self.panelMargin
        let maxY = screenFrame.maxY - panel.frame.height - Self.panelMargin
        origin.x = min(max(screenFrame.minX + Self.panelMargin, origin.x), maxX)
        origin.y = min(max(screenFrame.minY + Self.panelMargin, origin.y), maxY)
        panel.setFrameOrigin(origin)
    }

    private static func defaultFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: Self.defaultSize)
        let width = min(Self.defaultSize.width, visible.width * 0.9)
        let height = min(Self.defaultSize.height, visible.height * 0.9)
        let origin = NSPoint(x: visible.midX - width / 2, y: visible.midY - height / 2)
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        self.onClose()
    }
}
