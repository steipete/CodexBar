import AppKit
import SwiftUI

/// Card rows draw their own selection state. Keeping AppKit's parallel highlight hidden also
/// prevents newer menu implementations from painting a native selection behind the custom view.
final class MenuCardMenuItem: NSMenuItem {
    override var isHighlighted: Bool {
        false
    }
}

extension StatusItemController {
    func refreshMenuCardHeights(in menu: NSMenu) {
        let width = self.renderedMenuWidth(for: menu)
        for item in menu.items {
            if let view = item.view as? PersistentRefreshMenuView {
                guard abs(view.frame.width - width) > 0.5 else { continue }
                view.applySize(width: width, height: PersistentRefreshRowMetrics.defaults.rowHeight)
                continue
            }
            guard let view = item.view, let measuring = view as? any MenuCardMeasuring else { continue }
            guard abs(view.frame.width - width) > 0.5 else { continue }
            let id = item.representedObject as? String ?? "menuCard"
            let scope = self.menuProvider(for: menu)?.rawValue ?? id
            let height = self.cachedMenuCardHeight(for: id, scope: scope, width: width) {
                self.menuCardHeight(for: view, width: width)
            }
            measuring.applyMeasuredSize(width: width, height: height)
        }
    }

    func makeMenuCardItem(
        _ view: some View,
        id: String,
        width: CGFloat,
        heightCacheScope: String? = nil,
        heightCacheFingerprint: String? = nil,
        submenu: NSMenu? = nil,
        submenuIndicatorAlignment: Alignment = .topTrailing,
        submenuIndicatorTopPadding: CGFloat = 8,
        containsInteractiveControls: Bool = false,
        usesGPUSelection: Bool = false,
        onClick: (() -> Void)? = nil) -> NSMenuItem
    {
        let allowsMenuHighlight = submenu != nil || onClick != nil
        if !self.menuCardRenderingEnabledForController {
            let item = NSMenuItem()
            item.title = ""
            item.isEnabled = allowsMenuHighlight
            item.representedObject = id
            item.submenu = submenu
            if submenu != nil {
                item.target = self
                item.action = #selector(self.menuCardNoOp(_:))
            }
            return item
        }

        // Content is erased so every row shares one outer AppKit class. Tab switches can replant
        // standard and GPU-selection payloads in place instead of detaching `item.view`.
        // Every hosted card row gets the action handler, so Overview and account layouts can open details too.
        let actionTarget = MenuCardActionTarget()
        let cardAction = ProviderCardAction(perform: { [weak self, actionTarget] action in
            guard let self else { return }
            actionTarget.item?.menu?.cancelTracking()
            let (selector, object) = self.selector(for: action)
            let sender = NSMenuItem()
            sender.representedObject = object
            NSApp.sendAction(selector, to: self, from: sender)
        })
        let payload = MenuCardRowPayload(
            content: AnyView(view
                .environment(\.providerMenuChartSettings, self.settings)
                .environment(\.providerCardAction, cardAction)),
            showsSubmenuIndicator: submenu != nil,
            submenuIndicatorAlignment: submenuIndicatorAlignment,
            submenuIndicatorTopPadding: submenuIndicatorTopPadding,
            allowsMenuHighlight: allowsMenuHighlight,
            containsInteractiveControls: containsInteractiveControls,
            usesGPUSelection: usesGPUSelection,
            onClick: onClick,
            remeasure: { [weak self] container in
                // NSMenu tracking does not drain main-actor Tasks, but the main queue still runs; by then
                // SwiftUI has applied the state change that altered the content height.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.remeasureMenuCard(container)
                    }
                }
            })
        let hosting: ErasedMenuCardHostingView
        if let recycled = self.takeRecyclableMenuCardView(
            for: id,
            as: ErasedMenuCardHostingView.self)
        {
            self.replantMenuCardRowPayload(payload, into: recycled)
            hosting = recycled
        } else {
            hosting = MenuRowContainerView(
                payload: payload,
                refreshMonitor: self.menuCardRefreshMonitor)
        }
        let height = self.cachedMenuCardHeight(
            for: id,
            scope: heightCacheScope ?? id,
            width: width,
            fingerprint: heightCacheFingerprint)
        {
            self.menuCardHeight(for: hosting, width: width)
        }
        hosting.applyMeasuredSize(width: width, height: height)
        let item = self.makeMenuCardNSMenuItem(
            hosting: hosting,
            id: id,
            submenu: submenu,
            isEnabled: allowsMenuHighlight || containsInteractiveControls)
        actionTarget.item = item
        return item
    }

    /// Wraps a measured hosting view in the `NSMenuItem` the menu installs, wiring submenu routing.
    private func makeMenuCardNSMenuItem(
        hosting: NSView,
        id: String,
        submenu: NSMenu?,
        isEnabled: Bool) -> NSMenuItem
    {
        let item = MenuCardMenuItem()
        // NSMenuItem()'s default title is the literal string "NSMenuItem"; Tahoe's
        // NSMenu paints that fallback title for frames where a row's view is
        // detached mid-mutation. Keep the fallback render blank instead.
        item.title = ""
        item.view = hosting
        item.isEnabled = isEnabled
        item.representedObject = id
        item.submenu = submenu
        if submenu != nil {
            item.target = self
            item.action = #selector(self.menuCardNoOp(_:))
        }
        return item
    }

    /// Adds the header and usage row of a sectioned card.
    ///
    /// A submenu opens from anywhere on its row. When the row has one and an inline chart to hang it on,
    /// provider details move to a row of their own below, so the submenu follows the pointer over the usage
    /// part only and not over the details and their pickers.
    func addUsageMenuCardSection(
        to menu: NSMenu,
        model: UsageMenuCardView.Model,
        layoutModel: UsageMenuCardView.Model,
        width: CGFloat,
        submenu: NSMenu?)
    {
        let scope = layoutModel.provider.rawValue
        let bottomPadding: CGFloat = layoutModel.creditsText != nil ? 4 : 6
        let splitsDetails = submenu != nil && layoutModel.inlineUsageDashboard != nil &&
            !layoutModel.providerDetails.isEmpty
        menu.addItem(self.makeMenuCardItem(
            UsageMenuCardHeaderAndUsageSectionView(
                model: model,
                layoutModel: layoutModel,
                bottomPadding: bottomPadding,
                width: width,
                showsProviderDetails: !splitsDetails),
            id: "menuCardUsage",
            width: width,
            heightCacheScope: scope,
            heightCacheFingerprint: layoutModel.heightFingerprint(
                section: splitsDetails ? "usageWithoutDetails" : "usage"),
            submenu: submenu,
            containsInteractiveControls: true))
        guard splitsDetails else { return }
        menu.addItem(.separator())
        menu.addItem(self.makeMenuCardItem(
            UsageMenuCardProviderDetailsSectionView(
                model: model,
                topPadding: 6,
                bottomPadding: bottomPadding,
                width: width),
            id: "menuCardDetails",
            width: width,
            heightCacheScope: scope,
            heightCacheFingerprint: layoutModel.heightFingerprint(section: "details"),
            containsInteractiveControls: true))
    }

    /// Gives a row the height its content has now, after the content changed height on its own.
    func remeasureMenuCard(_ container: MenuRowContainerView) {
        // Cached heights are keyed by content, which does not know the card's own view state.
        self.menuCardHeightCache.removeAll(keepingCapacity: true)
        let width = container.frame.width
        guard width > 0 else { return }
        let height = self.menuCardHeight(for: container, width: width)
        guard abs(container.intrinsicContentSize.height - height) > 0.5 else { return }
        container.applyMeasuredSize(width: width, height: height)
        // AppKit's table-backed menu keeps an attached row's height (#3549), so the item is presented again.
        guard let item = container.enclosingMenuItem, let menu = item.menu else { return }
        let index = menu.index(of: item)
        guard index >= 0 else { return }
        menu.removeItem(at: index)
        menu.insertItem(item, at: index)
    }

    private func menuCardHeight(for view: NSView, width: CGFloat) -> CGFloat {
        let basePadding: CGFloat = 6
        let descenderSafety: CGFloat = 1

        if let measured = view as? MenuCardMeasuring {
            return max(1, ceil(measured.measuredHeight(width: width) + basePadding + descenderSafety))
        }

        view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1))
        let fitted = view.fittingSize
        return max(1, ceil(fitted.height + basePadding + descenderSafety))
    }
}

/// Resolves the hosting menu when a card action fires, so tracking ends from whichever menu shows the row.
@MainActor
final class MenuCardActionTarget {
    weak var item: NSMenuItem?
}
