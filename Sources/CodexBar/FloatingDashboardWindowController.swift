import AppKit
import Observation
import SwiftUI

@MainActor
final class FloatingDashboardWindowController {
    private var panel: NSPanel?
    private let store: UsageStore
    private let settings: SettingsStore
    private nonisolated(unsafe) var moveObserver: NSObjectProtocol?
    private var lastHorizontal: Bool

    init(store: UsageStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        self.lastHorizontal = settings.floatingDashboardHorizontal
    }

    func show() {
        if let panel {
            panel.orderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false

        let view = FloatingDashboardView(store: self.store, settings: self.settings)
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting

        let size = hosting.fittingSize
        panel.setContentSize(size)
        self.applyPosition(to: panel, size: size)

        panel.orderFront(nil)
        self.panel = panel

        self.moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.savePosition()
            }
        }

        self.observeStoreChanges()
    }

    func hide() {
        if let observer = self.moveObserver {
            NotificationCenter.default.removeObserver(observer)
            self.moveObserver = nil
        }
        self.panel?.orderOut(nil)
        self.panel = nil
    }

    func toggle() {
        if self.panel != nil {
            self.hide()
        } else {
            self.show()
        }
    }

    private func applyPosition(to panel: NSPanel, size: NSSize) {
        if let saved = self.settings.floatingDashboardPosition,
           let x = saved["x"],
           let y = saved["y"]
        {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let x = visibleFrame.maxX - size.width - 20
            let y = visibleFrame.minY + 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func savePosition() {
        guard let frame = self.panel?.frame else { return }
        self.settings.floatingDashboardPosition = [
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y),
        ]
    }

    private func observeStoreChanges() {
        withObservationTracking {
            _ = self.store.menuObservationToken
            _ = self.settings.floatingDashboardHorizontal
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.panel != nil else { return }
                self.resizePanel()
                self.observeStoreChanges()
            }
        }
    }

    private func resizePanel() {
        guard self.panel != nil else { return }
        // If the layout orientation changed, recreate the panel to avoid constraint crashes
        let currentHorizontal = self.settings.floatingDashboardHorizontal
        if currentHorizontal != self.lastHorizontal {
            self.lastHorizontal = currentHorizontal
            self.recreatePanel()
            return
        }
        guard let panel, let hosting = panel.contentView as? NSHostingView<FloatingDashboardView> else { return }
        let origin = panel.frame.origin
        let newSize = hosting.fittingSize
        panel.setContentSize(newSize)
        panel.setFrameOrigin(origin)
    }

    private func recreatePanel() {
        let savedOrigin = self.panel?.frame.origin
        self.hide()

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false

        let view = FloatingDashboardView(store: self.store, settings: self.settings)
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting

        let size = hosting.fittingSize
        panel.setContentSize(size)
        if let origin = savedOrigin {
            panel.setFrameOrigin(origin)
        } else {
            self.applyPosition(to: panel, size: size)
        }

        panel.orderFront(nil)
        self.panel = panel

        self.moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.savePosition()
            }
        }

        self.observeStoreChanges()
    }

    deinit {
        if let observer = self.moveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
