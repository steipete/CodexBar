import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI

@MainActor
final class NotchUsageOverlayController {
    private static let expandDwell: Duration = .milliseconds(350)
    private static let collapseGrace: Duration = .milliseconds(400)
    private static let collapseAnimation: Duration = .milliseconds(350)

    private let store: UsageStore
    private let settings: SettingsStore
    private let viewState = NotchUsageOverlayViewState()

    /// Owned by `StatusItemController`; the overlay reads its published sessions instead of
    /// running a second scanner. Nil until the status controller exists.
    var agentSessions: AgentSessionsStore? {
        didSet {
            guard oldValue !== self.agentSessions, self.panel != nil else { return }
            self.rebuildPanel()
        }
    }

    private var panel: NotchHoverPanel?
    private weak var screen: NSScreen?
    private var screenParametersObserver: NSObjectProtocol?
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var isStarted = false
    private var isPointerInside = false
    /// Owns hold/toggle semantics; while it is holding, losing the pointer must not collapse.
    private var hotkeyState = NotchHotkeyState()

    init(store: UsageStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    func start() {
        guard !self.isStarted else { return }
        self.isStarted = true
        self.observeSettingsChanges()
        self.screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateActivation()
            }
        }
        self.updateActivation()
        self.installHotkeyHandlers()
    }

    func stop() {
        guard self.isStarted || self.panel != nil else { return }
        self.isStarted = false
        self.hoverTask?.cancel()
        self.hoverTask = nil
        self.collapseTask?.cancel()
        self.collapseTask = nil
        if let observer = self.screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
            self.screenParametersObserver = nil
        }
        self.closePanel()
    }

    private func installHotkeyHandlers() {
        KeyboardShortcuts.onKeyDown(for: .showNotchOverlay) { [weak self] in
            MainActor.assumeIsolated {
                self?.handleHotkeyDown()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .showNotchOverlay) { [weak self] in
            MainActor.assumeIsolated {
                self?.handleHotkeyUp()
            }
        }
    }

    private func handleHotkeyDown() {
        guard self.isStarted, self.settings.notchUsageSummaryEnabled else { return }
        // The panel only exists once a notched screen is present; activate on demand so the
        // shortcut works even when the pointer has never touched the notch.
        if self.panel == nil {
            self.updateActivation()
        }
        // Still no panel means no notched screen; mutating the hotkey state or the view state
        // here would strand `isExpanded` and leave a panel created later stuck un-expandable.
        guard self.panel != nil else { return }
        switch self.hotkeyState.press(
            mode: self.settings.notchHotkeyMode,
            isExpanded: self.viewState.isExpanded)
        {
        case .expand:
            self.hoverTask?.cancel()
            self.collapseTask?.cancel()
            self.expandPanel()
        case .collapse:
            self.collapsePanel()
        case .ignore:
            break
        }
    }

    private func handleHotkeyUp() {
        switch self.hotkeyState.release(
            mode: self.settings.notchHotkeyMode,
            isPointerInside: self.isPointerInside)
        {
        case .collapse:
            self.collapsePanel()
        case .expand, .ignore:
            break
        }
    }

    private func observeSettingsChanges() {
        withObservationTracking {
            _ = self.settings.notchUsageSummaryEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.observeSettingsChanges()
                self.updateActivation()
            }
        }
    }

    private func updateActivation() {
        guard self.isStarted,
              self.settings.notchUsageSummaryEnabled,
              let notchedScreen = NotchGeometry.notchedScreen(),
              let notchRect = NotchGeometry.notchRect(for: notchedScreen)
        else {
            self.closePanel()
            return
        }

        if let panel = self.panel, self.screen === notchedScreen, !self.viewState.isExpanded {
            self.viewState.notchHeight = notchRect.height
            panel.setFrame(self.collapsedFrame(notchRect: notchRect, screen: notchedScreen), display: true)
            return
        }

        self.closePanel()
        self.screen = notchedScreen
        self.viewState.notchHeight = notchRect.height
        self.createPanel(
            screen: notchedScreen,
            collapsedFrame: self.collapsedFrame(notchRect: notchRect, screen: notchedScreen))
    }

    private func createPanel(screen: NSScreen, collapsedFrame: CGRect) {
        let rootView = NotchUsageOverlayView(
            store: self.store,
            settings: self.settings,
            agentSessions: self.agentSessions,
            viewState: self.viewState)
        let hostingView = NotchHoverHostingView(rootView: rootView)
        // Without this the hosting view installs its content's ideal size as window constraints and
        // a tall provider list grows the panel past the screen; the controller owns the frame.
        hostingView.sizingOptions = []
        hostingView.onMouseEntered = { [weak self] in
            self?.handleMouseEntered()
        }
        hostingView.onMouseExited = { [weak self] in
            self?.handleMouseExited()
        }
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NotchHoverPanel(
            contentRect: collapsedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen)
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isExcludedFromWindowsMenu = true
        panel.setFrame(collapsedFrame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func handleMouseEntered() {
        self.isPointerInside = true
        self.collapseTask?.cancel()
        self.collapseTask = nil
        guard !self.viewState.isExpanded else { return }
        self.hoverTask?.cancel()
        self.hoverTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.expandDwell)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.isPointerInside else { return }
            self.expandPanel()
        }
    }

    private func handleMouseExited() {
        self.isPointerInside = false
        if !self.viewState.isExpanded {
            self.hoverTask?.cancel()
            self.hoverTask = nil
            return
        }

        self.collapseTask?.cancel()
        self.collapseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.collapseGrace)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.isPointerInside, !self.hotkeyState.isHolding
            else { return }
            self.collapsePanel()
        }
    }

    private func expandPanel() {
        self.viewState.isExpanded = true
        self.applyExpandedFrame()
    }

    /// Usage snapshots keep arriving while the panel is open, so the frame is re-measured whenever
    /// anything the measurement read changes. Without this the panel keeps the size it had when it
    /// opened and late-arriving bars are stuck behind a scroll.
    private func applyExpandedFrame() {
        guard self.viewState.isExpanded,
              let panel = self.panel,
              let screen = self.screen,
              let notchRect = NotchGeometry.notchRect(for: screen)
        else { return }

        var frame = panel.frame
        withObservationTracking {
            frame = self.expandedFrame(notchRect: notchRect, screen: screen)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyExpandedFrame()
            }
        }
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }

    private func collapsePanel() {
        guard let panel = self.panel,
              let screen = self.screen,
              let notchRect = NotchGeometry.notchRect(for: screen)
        else { return }

        self.viewState.isExpanded = false
        let collapsedFrame = self.collapsedFrame(notchRect: notchRect, screen: screen)
        self.collapseTask = Task { @MainActor [weak self, weak panel] in
            do {
                try await Task.sleep(for: Self.collapseAnimation)
            } catch {
                return
            }
            // Restore whenever the panel is still collapsed. Gating this on pointer position
            // instead would let a shortcut-collapse under a hovering pointer keep the expanded
            // frame alive as an invisible click trap; a re-expansion flips `isExpanded` back
            // (and cancels this task), so it can never fight a reopened panel.
            guard let self, let panel, !Task.isCancelled, !self.viewState.isExpanded
            else { return }
            panel.setFrame(collapsedFrame, display: true)
        }
    }

    private func closePanel() {
        self.hoverTask?.cancel()
        self.hoverTask = nil
        self.collapseTask?.cancel()
        self.collapseTask = nil
        self.isPointerInside = false
        self.viewState.gridContentHeight = 0
        self.viewState.bandContentHeight = 0
        self.hotkeyState.clear()
        self.viewState.isExpanded = false
        if let panel = self.panel {
            panel.orderOut(nil)
            panel.close()
            self.panel = nil
        }
        self.screen = nil
    }

    /// The collapsed hit area is exactly the camera housing. Widening it past the notch would let an
    /// invisible panel swallow clicks meant for a menu extra sitting flush against the housing.
    private func collapsedFrame(notchRect: CGRect, screen: NSScreen) -> CGRect {
        notchRect.intersection(screen.frame)
    }

    private func rebuildPanel() {
        self.closePanel()
        self.updateActivation()
    }

    /// Width comes from the smallest size that fits the tiles. Height is the sum of two
    /// independently capped sections: the provider grid and the session band. Each section's
    /// natural height comes from the view itself (`viewState`), which is the only figure that
    /// cannot drift from what SwiftUI laid out; the measured estimate covers the first frame,
    /// before the view has reported.
    private func expandedFrame(notchRect: CGRect, screen: NSScreen) -> CGRect {
        let model = NotchUsageOverlayModel.make(
            store: self.store,
            settings: self.settings,
            agentSessions: self.agentSessions)
        let content = NotchUsageOverlayContent(model: model)
        let padding = 2 * NotchUsageOverlayContent.horizontalPadding
        let width = min(
            max(self.naturalWidth(content.grid) + padding + Self.panelInset, notchRect.width + padding),
            max(1, screen.frame.width - 16))
        let innerWidth = max(1, width - Self.panelInset - padding)

        let gridNatural = self.viewState.gridContentHeight > 0
            ? self.viewState.gridContentHeight
            : self.measuredHeight(content.grid, width: innerWidth)
        var contentHeight = min(gridNatural, CGFloat(self.settings.notchProvidersMaxHeight))

        if model.sessionsBand != nil {
            let bandNatural = self.viewState.bandContentHeight > 0
                ? self.viewState.bandContentHeight
                : self.measuredHeight(content.band, width: innerWidth)
            contentHeight += min(bandNatural, CGFloat(self.settings.notchSessionsMaxHeight))
                + NotchUsageOverlayContent.sectionSpacing
        }
        contentHeight += NotchUsageOverlayContent.bottomPadding

        let height = min(notchRect.height + contentHeight + Self.panelInset, screen.frame.height * 0.9)
        let x = min(
            max(notchRect.midX - width / 2, screen.frame.minX),
            screen.frame.maxX - width)
        let y = max(screen.frame.minY, screen.frame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Room the rounded background leaves inside the panel.
    private static let panelInset: CGFloat = 8

    /// Smallest width that fits the tiles. Tiles claim `maxWidth: .infinity`, so proposing an
    /// unbounded width would hand back the whole screen.
    private func naturalWidth(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return max(hosting.fittingSize.width, NotchUsageOverlayContent.maximumTileWidth)
    }

    private func measuredHeight(_ view: some View, width: CGFloat) -> CGFloat {
        let size = NSHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return max(size.height, 0)
    }
}

private final class NotchHoverPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        false
    }
}

private final class NotchHoverHostingView: NSHostingView<NotchUsageOverlayView> {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.window?.acceptsMouseMovedEvents = true
        self.updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            self.removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil)
        self.addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        self.onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        self.onMouseExited?()
    }
}
