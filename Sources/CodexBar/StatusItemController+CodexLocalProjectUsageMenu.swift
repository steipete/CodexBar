import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    static let codexLocalProjectUsageSubmenuID = "codexLocalProjectUsageSubmenu"
    private static let codexLocalProjectUsageProgressID = "codexLocalProjectUsageProgress"

    func observeCodexLocalProjectUsageProgressChanges() {
        withObservationTracking {
            _ = self.store.codexLocalProjectUsageProgress
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeCodexLocalProjectUsageProgressChanges()
                self.updateCodexLocalProjectUsageRows()
            }
        }
    }

    @discardableResult
    func addCodexLocalProjectUsageMenuItemIfNeeded(to menu: NSMenu, provider: UsageProvider, width: CGFloat) -> Bool {
        guard provider == .codex else { return false }
        guard self.settings.codexLocalProjectUsageEnabled else { return false }

        let submenuWidth = max(width, CodexLocalProjectUsageSubmenuLayout.menuWidth)
        let submenu = self.makeHostedSubviewPlaceholderMenu(
            chartID: Self.codexLocalProjectUsageSubmenuID,
            width: submenuWidth)
        let item = NSMenuItem()
        item.target = self
        item.action = #selector(self.menuCardNoOp(_:))
        item.isEnabled = true
        item.title = L("codex_workspaces_title")
        item.representedObject = "codexLocalProjectUsage"
        item.submenu = submenu
        menu.addItem(item)
        self.codexLocalProjectUsageRows.add(item)
        self.codexLocalProjectUsageRowWidths.setObject(NSNumber(value: Double(width)), forKey: item)
        self.updateCodexLocalProjectUsageRow(item)
        return true
    }

    func addCodexLocalProjectUsageMenuSection(to menu: NSMenu, provider: UsageProvider, width: CGFloat) {
        guard provider == .codex, self.settings.codexLocalProjectUsageEnabled else { return }
        let hasCost = menu.items.contains { ($0.representedObject as? String) == "menuCardCost" }
        let hasCreditsOrExtraUsage = menu.items.contains {
            let identifier = $0.representedObject as? String
            return identifier == "menuCardCredits" || identifier == "menuCardExtraUsage"
        }
        if !hasCost, hasCreditsOrExtraUsage, menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
        if self.addCodexLocalProjectUsageMenuItemIfNeeded(to: menu, provider: provider, width: width) {
            menu.addItem(.separator())
        }
    }

    func updateCodexLocalProjectUsageRows() {
        for row in self.codexLocalProjectUsageRows.allObjects {
            self.updateCodexLocalProjectUsageRow(row)
        }
    }

    func updateCodexLocalProjectUsageRow(_ item: NSMenuItem) {
        let title = L("codex_workspaces_title")
        item.title = title
        let subtitle = self.store.codexLocalProjectUsageRowSubtitle
        if self.store.codexLocalProjectUsageRefreshInFlight {
            self.clearSubtitle(from: item, title: title)
            if let subtitle {
                self.updateOrInsertProgressRow(
                    after: item,
                    subtitle: subtitle,
                    width: self.codexLocalProjectUsageRowWidth(for: item))
            }
            return
        }
        self.removeProgressRow(after: item)
        if let subtitle {
            guard self.currentSubtitle(for: item) != subtitle else { return }
            self.applySubtitle(subtitle, to: item, title: title)
        } else {
            guard self.currentSubtitle(for: item) != nil else { return }
            self.clearSubtitle(from: item, title: title)
        }
    }

    private func codexLocalProjectUsageRowWidth(for item: NSMenuItem) -> CGFloat {
        self.codexLocalProjectUsageRowWidths.object(forKey: item)?.doubleValue ?? 0
    }

    private func updateOrInsertProgressRow(after item: NSMenuItem, subtitle: String, width: CGFloat) {
        guard let menu = item.menu else { return }
        if let progressItem = self.progressRow(after: item) {
            progressItem.title = subtitle
            (progressItem.view as? CodexLocalProjectUsageProgressMenuRowView)?.update(subtitle: subtitle)
            return
        }

        let progressItem = NSMenuItem(title: subtitle, action: nil, keyEquivalent: "")
        progressItem.isEnabled = false
        progressItem.representedObject = Self.codexLocalProjectUsageProgressID
        progressItem.view = CodexLocalProjectUsageProgressMenuRowView(width: width, subtitle: subtitle)
        guard let index = menu.items.firstIndex(where: { $0 === item }) else { return }
        menu.insertItem(progressItem, at: index + 1)
    }

    private func removeProgressRow(after item: NSMenuItem) {
        guard let menu = item.menu, let progressItem = self.progressRow(after: item) else { return }
        menu.removeItem(progressItem)
    }

    private func progressRow(after item: NSMenuItem) -> NSMenuItem? {
        guard let menu = item.menu,
              let index = menu.items.firstIndex(where: { $0 === item }),
              index + 1 < menu.items.count
        else { return nil }
        let candidate = menu.items[index + 1]
        guard (candidate.representedObject as? String) == Self.codexLocalProjectUsageProgressID else {
            return nil
        }
        return candidate
    }

    private func clearSubtitle(from item: NSMenuItem, title: String) {
        item.view = nil
        item.toolTip = nil
        item.title = title
        if #available(macOS 14.4, *) {
            item.subtitle = ""
        }
    }

    private func currentSubtitle(for item: NSMenuItem) -> String? {
        if #available(macOS 14.4, *), let subtitle = item.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        return item.toolTip?.components(separatedBy: "—").last?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc
    func openCodexLocalProjectUsageWindowFromMenu(_ sender: Any?) {
        self.openCodexLocalProjectUsageWindow()
    }

    func openCodexLocalProjectUsageWindow() {
        let controller = self.codexLocalProjectUsageWindow ?? CodexLocalProjectUsageWindowController(
            store: self.store,
            settings: self.settings,
            selection: self.codexLocalProjectUsageInspectorSelection)
        self.codexLocalProjectUsageWindow = controller
        controller.showAndRefresh()
    }

    func openCodexLocalProjectUsageSessionsWindow() {
        let controller = self.codexLocalProjectUsageWindow ?? CodexLocalProjectUsageWindowController(
            store: self.store,
            settings: self.settings,
            selection: self.codexLocalProjectUsageInspectorSelection)
        self.codexLocalProjectUsageWindow = controller
        controller.showSessions()
    }
}

private final class CodexLocalProjectUsageProgressMenuRowView: NSView {
    private static let rowHeight: CGFloat = 24
    private let subtitleField: NSTextField
    private let progressIndicator = NSProgressIndicator()

    override var intrinsicContentSize: NSSize {
        NSSize(width: self.frame.width > 0 ? self.frame.width : NSView.noIntrinsicMetric, height: Self.rowHeight)
    }

    override var fittingSize: NSSize {
        NSSize(width: self.frame.width, height: Self.rowHeight)
    }

    init(width: CGFloat, subtitle: String) {
        self.subtitleField = NSTextField(labelWithString: subtitle)
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: width, height: Self.rowHeight)))
        self.setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(subtitle: String) {
        self.subtitleField.stringValue = subtitle
    }

    private func setupView() {
        self.subtitleField.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        self.subtitleField.textColor = NSColor.secondaryLabelColor
        self.subtitleField.lineBreakMode = .byTruncatingTail
        self.subtitleField.translatesAutoresizingMaskIntoConstraints = false

        self.progressIndicator.style = .spinning
        self.progressIndicator.controlSize = .small
        self.progressIndicator.isIndeterminate = true
        self.progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.subtitleField)
        self.addSubview(self.progressIndicator)

        NSLayoutConstraint.activate([
            self.subtitleField.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 18),
            self.subtitleField.trailingAnchor.constraint(
                lessThanOrEqualTo: self.progressIndicator.leadingAnchor,
                constant: -10),
            self.subtitleField.centerYAnchor.constraint(equalTo: self.centerYAnchor),

            self.progressIndicator.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -18),
            self.progressIndicator.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.progressIndicator.widthAnchor.constraint(equalToConstant: 16),
            self.progressIndicator.heightAnchor.constraint(equalToConstant: 16),
        ])
        self.progressIndicator.startAnimation(nil)
    }
}
