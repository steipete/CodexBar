import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct SettingsSidebarToolbarTests {
    @Test
    func `collapsing the sidebar hides sorting controls and reopening restores them`() async throws {
        guard #available(macOS 26.0, *) else { return }
        _ = NSApplication.shared
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let selection = PreferencesSelection(userDefaults: InMemoryUserDefaults())
        selection.pane = .menu
        let view = PreferencesView(
            settings: settings,
            store: store,
            updater: DisabledUpdaterController(),
            selection: selection)
            .defaultAppStorage(InMemoryUserDefaults())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.contentViewController = NSHostingController(rootView: view)
        defer { window.contentViewController = nil }
        try await self.settle(window)
        let content = try #require(window.contentView)
        let split = try #require(self.splitView(in: content))
        let controller = try #require(split.delegate as? NSSplitViewController)
        let sidebar = try #require(controller.splitViewItems.first)
        let toolbar = try #require(window.toolbar)
        let sortingLabels = Set([L("Sort providers alphabetically"), L("Provider sorting")])
        func visibleSortingLabels() -> Set<String> {
            Set(toolbar.items.filter { !$0.isHidden }.map(\.label)).intersection(sortingLabels)
        }
        #expect(visibleSortingLabels() == sortingLabels)
        sidebar.isCollapsed = true
        try await self.settle(window)
        #expect(visibleSortingLabels().isEmpty)
        sidebar.isCollapsed = false
        try await self.settle(window)
        #expect(visibleSortingLabels() == sortingLabels)
    }

    private func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap { self.splitView(in: $0) }.first
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
