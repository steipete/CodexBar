import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Observable
private final class LayoutProbe {
    var height: CGFloat = 40
    @ObservationIgnored var layout: MenuCardLayoutAction?
}

private struct LayoutProbeView: View {
    let probe: LayoutProbe
    @Environment(\.menuCardLayout) private var layout

    var body: some View {
        Color.clear.frame(height: self.recordedHeight())
    }

    private func recordedHeight() -> CGFloat {
        self.probe.layout = self.layout
        return self.probe.height
    }
}

extension StatusMenuTests {
    private func makeDetailsRowController() -> StatusItemController {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        return StatusItemController(
            store: self.makeCodexStore(settings: settings, dashboardAuthorized: false),
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
    }

    @Test
    func `provider details get their own row only below a usage submenu`() async throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }
        let controller = self.makeDetailsRowController()
        defer { controller.releaseStatusItemsForTesting() }
        let model = try await ClaudePlatformAWSCardAnatomyRenderTests.syntheticCard().model
        let ids: (NSMenu) -> [String?] = { $0.items.map { $0.representedObject as? String } }

        let hovered = NSMenu()
        controller.addUsageMenuCardSection(
            to: hovered, model: model, layoutModel: model, width: 310, submenu: NSMenu())
        #expect(ids(hovered) == ["menuCardUsage", nil, "menuCardDetails"])
        #expect(hovered.items[0].submenu != nil)
        let details = hovered.items[2]
        #expect(details.submenu == nil)
        // The pickers stay clickable, but the row neither highlights nor opens anything.
        #expect(details.isEnabled)
        #expect((details.view as? ErasedMenuCardHostingView)?.allowsMenuHighlight == false)

        let plain = NSMenu()
        controller.addUsageMenuCardSection(
            to: plain, model: model, layoutModel: model, width: 310, submenu: nil)
        #expect(ids(plain) == ["menuCardUsage"])
        let plainHeight = try #require(plain.items[0].view?.frame.height)
        let usageHeight = try #require(hovered.items[0].view?.frame.height)
        let detailsHeight = try #require(details.view?.frame.height)
        #expect(usageHeight < plainHeight)
        #expect(detailsHeight > 100)
    }

    @Test
    func `content that changes its own height re-measures the row hosting it now`() async throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }
        let controller = self.makeDetailsRowController()
        defer { controller.releaseStatusItemsForTesting() }

        let probe = LayoutProbe()
        let menu = NSMenu()
        menu.addItem(.separator())
        let live = NSMenuItem()
        do {
            // A reconcile moves the view to the item already in the menu and drops the item it was built for.
            let built = controller.makeMenuCardItem(
                LayoutProbeView(probe: probe), id: "probe", width: 300, containsInteractiveControls: true)
            let view = built.view
            built.view = nil
            live.view = view
        }
        menu.addItem(live)
        let container = try #require(live.view as? MenuRowContainerView)
        let before = container.intrinsicContentSize.height

        probe.height = 90
        let invalidate = try #require(probe.layout?.invalidate)
        invalidate()
        try await Task.sleep(for: .milliseconds(50))

        #expect(container.intrinsicContentSize.height == before + 50)
        #expect(container.frame.height == before + 50)
        // The item is presented again in place, with its view still attached.
        #expect(menu.items.count == 2)
        #expect(menu.items[1] === live)
        #expect(live.view === container)
    }
}
