import AppKit
import CodexBarCore
import SwiftUI

// MARK: - NSMenu construction

extension StatusItemController {
    private static let menuCardWidth: CGFloat = 300

    func makeMenu() -> NSMenu {
        guard self.shouldMergeIcons else {
            return self.makeMenu(for: nil)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        self.populateMenu(menu)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if self.shouldMergeIcons {
            self.selectedMenuProvider = self.resolvedMenuProvider()
            self.lastMenuProvider = self.selectedMenuProvider ?? .codex
            self.refreshMenuCardHeights(in: menu)
        } else {
            self.refreshMenuCardHeights(in: menu)
            if let provider = self.menuProviders[ObjectIdentifier(menu)] {
                self.lastMenuProvider = provider
            } else {
                self.lastMenuProvider = self.store.enabledProviders().first ?? .codex
            }
        }
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let selectedProvider = self.resolvedMenuProvider()
        let enabledProviders = self.store.enabledProviders()
        let descriptor = MenuDescriptor.build(
            provider: selectedProvider,
            store: self.store,
            settings: self.settings,
            account: self.account)
        let dashboard = self.store.openAIDashboard
        let openAIWebEligible = selectedProvider == .codex &&
            self.settings.openAIDashboardEnabled &&
            self.store.openAIDashboardRequiresLogin == false &&
            dashboard != nil
        let hasCreditsHistory = openAIWebEligible && !(dashboard?.creditEvents ?? []).isEmpty
        let hasUsageBreakdown = openAIWebEligible && !(dashboard?.usageBreakdown ?? []).isEmpty
        let currentProvider = selectedProvider ?? enabledProviders.first ?? .codex
        let hasCostHistory = self.settings.isCCUsageCostUsageEffectivelyEnabled(for: currentProvider) &&
            (self.store.tokenSnapshot(for: currentProvider)?.daily.isEmpty == false)
        let hasOpenAIWebMenuItems = hasCreditsHistory || hasUsageBreakdown || hasCostHistory

        if enabledProviders.count > 1 {
            let switcherItem = self.makeProviderSwitcherItem(
                providers: enabledProviders,
                selected: selectedProvider,
                menu: menu)
            menu.addItem(switcherItem)
            menu.addItem(.separator())
        }

        if let model = self.menuCardModel(for: selectedProvider) {
            let cardView = UsageMenuCardView(model: model)
            let hosting = NSHostingView(rootView: cardView)
            // Important: constrain width before asking SwiftUI for the fitting height, otherwise text wrapping
            // changes the required height and the menu item becomes visually "squeezed".
            hosting.frame = NSRect(origin: .zero, size: NSSize(width: Self.menuCardWidth, height: 1))
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize
            hosting.frame = NSRect(origin: .zero, size: NSSize(width: Self.menuCardWidth, height: size.height))
            let item = NSMenuItem()
            item.view = hosting
            item.isEnabled = false
            item.representedObject = "menuCard"
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if hasOpenAIWebMenuItems {
            // Only show these when we actually have additional data.
            if hasCreditsHistory {
                _ = self.addCreditsHistorySubmenu(to: menu)
            }
            if hasUsageBreakdown {
                _ = self.addUsageBreakdownSubmenu(to: menu)
            }
            if hasCostHistory {
                _ = self.addCostHistorySubmenu(to: menu, provider: currentProvider)
            }
            menu.addItem(.separator())
        }

        let actionableSections = Array(descriptor.sections.suffix(2))
        for (index, section) in actionableSections.enumerated() {
            for entry in section.entries {
                switch entry {
                case let .text(text, style):
                    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    if style == .headline {
                        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
                    } else if style == .secondary {
                        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                        item.attributedTitle = NSAttributedString(
                            string: text,
                            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                    }
                    menu.addItem(item)
                case let .action(title, action):
                    let (selector, represented) = self.selector(for: action)
                    let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                    item.target = self
                    item.representedObject = represented
                    if let iconName = action.systemImageName,
                       let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
                    {
                        image.isTemplate = true
                        image.size = NSSize(width: 16, height: 16)
                        item.image = image
                    }
                    if case let .switchAccount(targetProvider) = action,
                       let subtitle = self.switchAccountSubtitle(for: targetProvider)
                    {
                        item.subtitle = subtitle
                        item.isEnabled = false
                    }
                    menu.addItem(item)
                case .divider:
                    menu.addItem(.separator())
                }
            }
            if index < actionableSections.count - 1 {
                menu.addItem(.separator())
            }
        }
    }

    func makeMenu(for provider: UsageProvider?) -> NSMenu {
        let targetProvider = provider ?? self.store.enabledProviders().first ?? .codex
        let descriptor = MenuDescriptor.build(
            provider: provider,
            store: self.store,
            settings: self.settings,
            account: self.account)
        let dashboard = self.store.openAIDashboard
        let openAIWebEligible = targetProvider == .codex &&
            self.settings.openAIDashboardEnabled &&
            self.store.openAIDashboardRequiresLogin == false &&
            dashboard != nil
        let hasCreditsHistory = openAIWebEligible && !(dashboard?.creditEvents ?? []).isEmpty
        let hasUsageBreakdown = openAIWebEligible && !(dashboard?.usageBreakdown ?? []).isEmpty
        let hasOpenAIWebMenuItems = hasCreditsHistory || hasUsageBreakdown

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        if let provider {
            self.menuProviders[ObjectIdentifier(menu)] = provider
        }

        if let model = self.menuCardModel(for: provider) {
            let cardView = UsageMenuCardView(model: model)
            let hosting = NSHostingView(rootView: cardView)
            // Important: constrain width before asking SwiftUI for the fitting height, otherwise text wrapping
            // changes the required height and the menu item becomes visually "squeezed".
            hosting.frame = NSRect(origin: .zero, size: NSSize(width: Self.menuCardWidth, height: 1))
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize
            hosting.frame = NSRect(origin: .zero, size: NSSize(width: Self.menuCardWidth, height: size.height))
            let item = NSMenuItem()
            item.view = hosting
            item.isEnabled = false
            item.representedObject = "menuCard"
            menu.addItem(item)
            // Keep the menu visually grouped.
            // If we show the credits history submenu, visually separate it from the menu card with a divider.
            if hasCreditsHistory || model.subtitleStyle == .info {
                menu.addItem(.separator())
            }
        }

        if hasOpenAIWebMenuItems {
            // Only show these when we actually have OpenAI web-only data.
            if hasCreditsHistory {
                _ = self.addCreditsHistorySubmenu(to: menu)
            }
            if hasUsageBreakdown {
                _ = self.addUsageBreakdownSubmenu(to: menu)
            }
            menu.addItem(.separator())
        }

        let actionableSections = Array(descriptor.sections.suffix(2))
        for (index, section) in actionableSections.enumerated() {
            for entry in section.entries {
                switch entry {
                case let .text(text, style):
                    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    if style == .headline {
                        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
                    } else if style == .secondary {
                        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                        item.attributedTitle = NSAttributedString(
                            string: text,
                            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                    }
                    menu.addItem(item)
                case let .action(title, action):
                    let (selector, represented) = self.selector(for: action)
                    let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                    item.target = self
                    item.representedObject = represented
                    if let iconName = action.systemImageName,
                       let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
                    {
                        image.isTemplate = true
                        image.size = NSSize(width: 16, height: 16)
                        item.image = image
                    }
                    if case let .switchAccount(targetProvider) = action,
                       let subtitle = self.switchAccountSubtitle(for: targetProvider)
                    {
                        item.subtitle = subtitle
                        item.isEnabled = false
                    }
                    menu.addItem(item)
                case .divider:
                    menu.addItem(.separator())
                }
            }
            if index < actionableSections.count - 1 {
                menu.addItem(.separator())
            }
        }
        return menu
    }

    private func makeProviderSwitcherItem(
        providers: [UsageProvider],
        selected: UsageProvider?,
        menu: NSMenu) -> NSMenuItem
    {
        let view = ProviderSwitcherView(
            providers: providers,
            selected: selected,
            width: Self.menuCardWidth,
            iconProvider: { [weak self] provider in
                self?.switcherIcon(for: provider) ?? NSImage()
            },
            onSelect: { [weak self, weak menu] provider in
                guard let self, let menu else { return }
                self.selectedMenuProvider = provider
                self.lastMenuProvider = provider
                self.populateMenu(menu)
                self.refreshMenuCardHeights(in: menu)
                self.applyIcon(phase: nil)
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    private func resolvedMenuProvider() -> UsageProvider? {
        let enabled = self.store.enabledProviders()
        if enabled.isEmpty { return .codex }
        if let selected = self.selectedMenuProvider, enabled.contains(selected) {
            return selected
        }
        return enabled.first
    }

    private func refreshMenuCardHeights(in menu: NSMenu) {
        // Re-measure the menu card height right before display to avoid stale/incorrect sizing when content
        // changes (e.g. dashboard error lines causing wrapping).
        if let item = menu.items.first(where: { ($0.representedObject as? String) == "menuCard" }),
           let view = item.view
        {
            view.frame = NSRect(origin: .zero, size: NSSize(width: Self.menuCardWidth, height: 1))
            view.layoutSubtreeIfNeeded()
            let height = view.fittingSize.height
            view.frame = NSRect(origin: .zero, size: NSSize(width: Self.menuCardWidth, height: height))
        }
    }

    private func switcherIcon(for provider: UsageProvider) -> NSImage {
        let snapshot = self.store.snapshot(for: provider)
        let showUsed = self.settings.usageBarsShowUsed
        let primary = showUsed ? snapshot?.primary.usedPercent : snapshot?.primary.remainingPercent
        let weekly = showUsed ? snapshot?.secondary?.usedPercent : snapshot?.secondary?.remainingPercent
        let credits = provider == .codex ? self.store.credits?.remaining : nil
        let stale = self.store.isStale(provider: provider)
        let style = self.store.style(for: provider)
        let indicator = self.store.statusIndicator(for: provider)
        let image = IconRenderer.makeIcon(
            primaryRemaining: primary,
            weeklyRemaining: weekly,
            creditsRemaining: credits,
            stale: stale,
            style: style,
            blink: 0,
            wiggle: 0,
            tilt: 0,
            statusIndicator: indicator)
        image.isTemplate = true
        return image
    }

    private func selector(for action: MenuDescriptor.MenuAction) -> (Selector, Any?) {
        switch action {
        case .refresh: (#selector(self.refreshNow), nil)
        case .dashboard: (#selector(self.openDashboard), nil)
        case .statusPage: (#selector(self.openStatusPage), nil)
        case let .switchAccount(provider): (#selector(self.runSwitchAccount(_:)), provider.rawValue)
        case .settings: (#selector(self.showSettingsGeneral), nil)
        case .about: (#selector(self.showSettingsAbout), nil)
        case .quit: (#selector(self.quit), nil)
        case let .copyError(message): (#selector(self.copyError(_:)), message)
        }
    }

    @discardableResult
    private func addCreditsHistorySubmenu(to menu: NSMenu) -> Bool {
        let events = self.store.openAIDashboard?.creditEvents ?? []
        guard !events.isEmpty else { return false }

        let item = NSMenuItem(title: "Credits usage history", action: nil, keyEquivalent: "")
        item.isEnabled = true
        let submenu = NSMenu()

        let limit = 20
        for event in events.prefix(limit) {
            let line = UsageFormatter.creditEventCompact(event)
            let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            row.isEnabled = false
            submenu.addItem(row)
        }
        if events.count > limit {
            submenu.addItem(.separator())
            let more = NSMenuItem(title: "Showing \(limit) of \(events.count)", action: nil, keyEquivalent: "")
            more.isEnabled = false
            submenu.addItem(more)
        }

        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    @discardableResult
    private func addUsageBreakdownSubmenu(to menu: NSMenu) -> Bool {
        let breakdown = self.store.openAIDashboard?.usageBreakdown ?? []
        guard !breakdown.isEmpty else { return false }

        let item = NSMenuItem(title: "Usage breakdown", action: nil, keyEquivalent: "")
        item.isEnabled = true
        let submenu = NSMenu()
        let chartView = UsageBreakdownChartMenuView(breakdown: breakdown)
        let hosting = NSHostingView(rootView: chartView)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: Self.menuCardWidth, height: 1))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: Self.menuCardWidth, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = false
        chartItem.representedObject = "usageBreakdownChart"
        submenu.addItem(chartItem)

        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    @discardableResult
    private func addCostHistorySubmenu(to menu: NSMenu, provider: UsageProvider) -> Bool {
        guard provider == .codex || provider == .claude else { return false }
        guard let tokenSnapshot = self.store.tokenSnapshot(for: provider) else { return false }
        guard !tokenSnapshot.daily.isEmpty else { return false }

        let item = NSMenuItem(title: "Cost history (30 days)", action: nil, keyEquivalent: "")
        item.isEnabled = true
        let submenu = NSMenu()
        let chartView = CCUsageCostChartMenuView(
            provider: provider,
            daily: tokenSnapshot.daily,
            totalCostUSD: tokenSnapshot.last30DaysCostUSD)
        let hosting = NSHostingView(rootView: chartView)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: Self.menuCardWidth, height: 1))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: Self.menuCardWidth, height: size.height))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = false
        chartItem.representedObject = "ccusageCostHistoryChart"
        submenu.addItem(chartItem)

        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    private func menuCardModel(for provider: UsageProvider?) -> UsageMenuCardView.Model? {
        let target = provider ?? self.store.enabledProviders().first ?? .codex
        let metadata = self.store.metadata(for: target)

        let snapshot = self.store.snapshot(for: target)
        let credits: CreditsSnapshot?
        let creditsError: String?
        let dashboard: OpenAIDashboardSnapshot?
        let dashboardError: String?
        let tokenSnapshot: CCUsageTokenSnapshot?
        let tokenError: String?
        if target == .codex {
            credits = self.store.credits
            creditsError = self.store.lastCreditsError
            dashboard = self.store.openAIDashboardRequiresLogin ? nil : self.store.openAIDashboard
            dashboardError = self.store.lastOpenAIDashboardError
            tokenSnapshot = self.store.tokenSnapshot(for: target)
            tokenError = self.store.tokenError(for: target)
        } else if target == .claude {
            credits = nil
            creditsError = nil
            dashboard = nil
            dashboardError = nil
            tokenSnapshot = self.store.tokenSnapshot(for: target)
            tokenError = self.store.tokenError(for: target)
        } else {
            credits = nil
            creditsError = nil
            dashboard = nil
            dashboardError = nil
            tokenSnapshot = nil
            tokenError = nil
        }

        let input = UsageMenuCardView.Model.Input(
            provider: target,
            metadata: metadata,
            snapshot: snapshot,
            credits: credits,
            creditsError: creditsError,
            dashboard: dashboard,
            dashboardError: dashboardError,
            tokenSnapshot: tokenSnapshot,
            tokenError: tokenError,
            account: self.account,
            isRefreshing: self.store.isRefreshing,
            lastError: self.store.error(for: target),
            usageBarsShowUsed: self.settings.usageBarsShowUsed,
            tokenCostUsageEnabled: self.settings.isCCUsageCostUsageEffectivelyEnabled(for: target),
            now: Date())
        return UsageMenuCardView.Model.make(input)
    }
}

private final class ProviderSwitcherView: NSView {
    private struct Segment {
        let provider: UsageProvider
        let image: NSImage
        let title: String
    }

    private let segments: [Segment]
    private let onSelect: (UsageProvider) -> Void
    private var buttons: [NSButton] = []
    private let selectedBackground = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    private let unselectedBackground = NSColor.clear.cgColor
    private let selectedTextColor = NSColor.labelColor
    private let unselectedTextColor = NSColor.secondaryLabelColor

    init(
        providers: [UsageProvider],
        selected: UsageProvider?,
        width: CGFloat,
        iconProvider: (UsageProvider) -> NSImage,
        onSelect: @escaping (UsageProvider) -> Void)
    {
        self.segments = providers.map { provider in
            Segment(
                provider: provider,
                image: iconProvider(provider),
                title: Self.switcherTitle(for: provider))
        }
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))

        func makeButton(index: Int, segment: Segment) -> NSButton {
            let button = PaddedToggleButton(
                title: segment.title,
                target: self,
                action: #selector(self.handleSelection(_:)))
            button.tag = index
            button.image = Self.paddedImage(segment.image, leading: 3)
            button.imagePosition = .imageLeading
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            button.setButtonType(.toggle)
            button.contentTintColor = self.unselectedTextColor
            button.alignment = .center
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.state = (selected == segment.provider) ? .on : .off
            button.translatesAutoresizingMaskIntoConstraints = false
            self.buttons.append(button)
            return button
        }

        for (index, segment) in self.segments.enumerated() {
            let button = makeButton(index: index, segment: segment)
            self.addSubview(button)
        }

        // Keep segment widths stable across selected/unselected to avoid shifting.
        for button in self.buttons {
            let width = ceil(Self.maxToggleWidth(for: button))
            if width > 0 {
                button.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
        }

        let outerPadding: CGFloat = 14
        let minimumGap: CGFloat = 8

        if self.buttons.count == 2 {
            let left = self.buttons[0]
            let right = self.buttons[1]
            let gap = right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: minimumGap)
            gap.priority = .defaultHigh
            NSLayoutConstraint.activate([
                left.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: outerPadding),
                left.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                right.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -outerPadding),
                right.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                gap,
            ])
        } else if self.buttons.count == 3 {
            let left = self.buttons[0]
            let mid = self.buttons[1]
            let right = self.buttons[2]

            let leftGap = mid.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: minimumGap)
            leftGap.priority = .defaultHigh
            let rightGap = right.leadingAnchor.constraint(
                greaterThanOrEqualTo: mid.trailingAnchor,
                constant: minimumGap)
            rightGap.priority = .defaultHigh

            NSLayoutConstraint.activate([
                left.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: outerPadding),
                left.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                mid.centerXAnchor.constraint(equalTo: self.centerXAnchor),
                mid.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                right.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -outerPadding),
                right.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                leftGap,
                rightGap,
            ])
        } else if let first = self.buttons.first {
            NSLayoutConstraint.activate([
                first.centerXAnchor.constraint(equalTo: self.centerXAnchor),
                first.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            ])
        }

        self.updateButtonStyles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @objc private func handleSelection(_ sender: NSButton) {
        let index = sender.tag
        guard self.segments.indices.contains(index) else { return }
        for (idx, button) in self.buttons.enumerated() {
            button.state = (idx == index) ? .on : .off
        }
        self.updateButtonStyles()
        self.onSelect(self.segments[index].provider)
    }

    private func updateButtonStyles() {
        for button in self.buttons {
            let isSelected = button.state == .on
            button.contentTintColor = isSelected ? self.selectedTextColor : self.unselectedTextColor
            button.layer?.backgroundColor = isSelected ? self.selectedBackground : self.unselectedBackground
        }
    }

    private static func maxToggleWidth(for button: NSButton) -> CGFloat {
        let originalState = button.state
        defer { button.state = originalState }

        button.state = .off
        button.layoutSubtreeIfNeeded()
        let offWidth = button.fittingSize.width

        button.state = .on
        button.layoutSubtreeIfNeeded()
        let onWidth = button.fittingSize.width

        return max(offWidth, onWidth)
    }

    private static func paddedImage(_ image: NSImage, leading: CGFloat) -> NSImage {
        let size = NSSize(width: image.size.width + leading, height: image.size.height)
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        let y = (size.height - image.size.height) / 2
        image.draw(
            at: NSPoint(x: leading, y: y),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1.0)
        newImage.unlockFocus()
        newImage.isTemplate = image.isTemplate
        return newImage
    }

    private static func switcherTitle(for provider: UsageProvider) -> String {
        switch provider {
        case .codex: "Codex"
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }
}

private final class PaddedToggleButton: NSButton {
    private let contentPadding = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(
            width: size.width + self.contentPadding.left + self.contentPadding.right,
            height: size.height + self.contentPadding.top + self.contentPadding.bottom)
    }
}

extension Notification.Name {
    static let codexbarOpenSettings = Notification.Name("codexbarOpenSettings")
    static let codexbarDebugBlinkNow = Notification.Name("codexbarDebugBlinkNow")
}
