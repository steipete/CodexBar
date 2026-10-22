import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct SettingsSidebarSizingTests {
    @Test
    func `native sidebar saves divider changes and restores them in a new view`() async throws {
        let width = SidebarWidth(value: 320)
        let firstWindow = self.makeWindow(width: width)
        try await self.settle(firstWindow)
        let firstContent = try #require(firstWindow.contentView)
        let firstSplit = try #require(self.splitView(in: firstContent))
        #expect(firstSplit.subviews[0].frame.width == 320)

        firstSplit.setPosition(300, ofDividerAt: 0)
        try await self.settle(firstWindow)
        #expect(width.value == 300)

        let secondWindow = self.makeWindow(width: width)
        try await self.settle(secondWindow)
        let secondContent = try #require(secondWindow.contentView)
        let secondSplit = try #require(self.splitView(in: secondContent))
        #expect(secondSplit.subviews[0].frame.width == 300)

        // The resize made SwiftUI reapply the column settings; collapsing must stay disabled afterwards.
        let firstController = try #require(firstSplit.delegate as? NSSplitViewController)
        let firstSidebar = try #require(firstController.splitViewItems.first)
        firstSplit.setPosition(0, ofDividerAt: 0)
        try await self.settle(firstWindow)
        #expect(firstSidebar.viewController.view.frame.width == 215)
        #expect(!firstSidebar.isCollapsed)
        #expect(!firstSidebar.canCollapse)
    }

    @Test
    func `native sidebar clamps saved widths and divider drags without collapsing`() async throws {
        // A width valid before the minimum changed must also restore safely.
        let width = SidebarWidth(value: 200)
        let window = self.makeWindow(width: width)
        try await self.settle(window)
        let content = try #require(window.contentView)
        let split = try #require(self.splitView(in: content))
        let controller = try #require(split.delegate as? NSSplitViewController)
        let sidebar = try #require(controller.splitViewItems.first)
        #expect(sidebar.viewController.view.frame.width == 215)
        #expect(width.value == 215)
        #expect(!sidebar.canCollapse)
        // Widening by dragging is unreliable in an offscreen window, so check the column bounds directly.
        #expect(sidebar.minimumThickness == SettingsPane.sidebarMinWidth)
        #expect(sidebar.maximumThickness == SettingsPane.sidebarMaxWidth)

        split.setPosition(0, ofDividerAt: 0)
        try await self.settle(window)
        #expect(sidebar.viewController.view.frame.width == 215)
        #expect(width.value == 215)
        #expect(!sidebar.isCollapsed)
        #expect(!sidebar.canCollapse)
    }

    @Test
    func `collapse guard only changes its enclosing sidebar`() {
        let controller = NSSplitViewController()
        let sidebarController = NSViewController()
        sidebarController.view = NSView()
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        let detailController = NSViewController()
        detailController.view = NSView()
        let detail = NSSplitViewItem(viewController: detailController)
        controller.addSplitViewItem(sidebar)
        controller.addSplitViewItem(detail)
        // Load the controller so the item views sit inside its split view on every OS release.
        controller.loadViewIfNeeded()
        sidebar.canCollapse = true
        detail.canCollapse = true

        let guardView = SettingsSidebarCollapseGuardView()
        detailController.view.addSubview(guardView)
        guardView.preventCollapse()
        #expect(sidebar.canCollapse)
        #expect(detail.canCollapse)

        sidebarController.view.addSubview(guardView)
        guardView.preventCollapse()
        #expect(!sidebar.canCollapse)
        #expect(detail.canCollapse)
    }

    private func makeWindow(width: SidebarWidth) -> NSWindow {
        _ = NSApplication.shared
        // Wide enough that the detail column's minimum width never limits how far the sidebar can grow.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: SettingsPane.windowHeight),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.contentViewController = NSHostingController(rootView: SidebarHarness(width: width))
        return window
    }

    private func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap { self.splitView(in: $0) }.first
    }

    private func settle(_ window: NSWindow) async throws {
        // Allow the hosting view's deferred layout and geometry callbacks to finish without showing a window.
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let contentView = window.contentView {
                self.splitView(in: contentView)?.layoutSubtreeIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
@Observable
private final class SidebarWidth {
    var value: Double

    init(value: Double) {
        self.value = value
    }
}

@MainActor
private struct SidebarHarness: View {
    @Bindable var width: SidebarWidth

    var body: some View {
        NavigationSplitView {
            Color.clear
                .toolbar(removing: .sidebarToggle)
                .modifier(SettingsSidebarSizing(width: self.$width.value))
        } detail: {
            Color.clear
        }
    }
}
