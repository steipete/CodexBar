#if canImport(JavaScriptCore)
import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    var shouldMergeIcons: Bool {
        self.settings.mergeIcons && (
            self.store.enabledProvidersForDisplay().count > 1 ||
                !self.topLevelUserProviderPlugins().isEmpty)
    }

    static func isUserPluginSelection(_ selection: ProviderSwitcherSelection?) -> Bool {
        selection?.instanceID.map { UserProviderPluginRegistry.plugin(for: $0) != nil } == true
    }

    func topLevelUserProviderPlugins() -> [UserProviderPlugin] {
        UserProviderPluginRegistry.all.filter {
            $0.manifest.topLevel && self.settings.isPluginEnabled($0.manifest.id)
        }
    }

    func switcherProviderIDs(enabledFirstPartyProviders: [UsageProvider]) -> [ProviderInstanceID] {
        enabledFirstPartyProviders.map(\.instanceID) + self.topLevelUserProviderPlugins().map(\.manifest.id)
    }

    static func resolvedSwitcherProviderID(
        providerIDs: [ProviderInstanceID],
        selectedProviderID: ProviderInstanceID?,
        fallbackProviderID: ProviderInstanceID) -> ProviderInstanceID
    {
        if let selectedProviderID, providerIDs.contains(selectedProviderID) {
            return selectedProviderID
        }
        return providerIDs.contains(fallbackProviderID) ? fallbackProviderID : providerIDs.first ?? fallbackProviderID
    }

    func overviewProviderIDs(enabledProviders: [UsageProvider]) -> [ProviderInstanceID] {
        let enabled = Set(enabledProviders)
        return self.store.enabledProvidersForDisplay().filter {
            $0.firstPartyProvider.map(enabled.contains) ?? true
        }
    }

    func includesOverviewTab(enabledProviders: [UsageProvider]) -> Bool {
        self.switcherProviderIDs(enabledFirstPartyProviders: enabledProviders).count > 1 &&
            !self.settings.resolvedMergedOverviewProviders(
                activeProviders: self.overviewProviderIDs(enabledProviders: enabledProviders),
                maxVisibleProviders: SettingsStore.mergedOverviewProviderLimit).isEmpty
    }

    func resolvedSwitcherSelection(
        enabledProviders: [UsageProvider],
        includesOverview: Bool) -> ProviderSwitcherSelection
    {
        if includesOverview, self.settings.mergedMenuLastSelectedWasOverview {
            return .overview
        }
        let providerIDs = self.switcherProviderIDs(enabledFirstPartyProviders: enabledProviders)
        let fallbackProviderID = (self.resolvedMenuProvider(enabledProviders: enabledProviders) ?? .codex).instanceID
        return .provider(Self.resolvedSwitcherProviderID(
            providerIDs: providerIDs,
            selectedProviderID: self.selectedMenuProvider,
            fallbackProviderID: fallbackProviderID))
    }

    func resolvedMergedMenuSelection(enabledProviders: [UsageProvider]) -> ProviderSwitcherSelection? {
        guard self.shouldMergeIcons,
              !self.switcherProviderIDs(enabledFirstPartyProviders: enabledProviders).isEmpty
        else { return nil }
        return self.resolvedSwitcherSelection(
            enabledProviders: enabledProviders,
            includesOverview: self.includesOverviewTab(enabledProviders: enabledProviders))
    }

    func addUserPluginMenuCards(
        to menu: NSMenu,
        width: CGFloat,
        selectedPluginID: ProviderInstanceID? = nil)
    {
        let hasTopLevelSwitcher = self.shouldMergeIcons &&
            self.switcherProviderIDs(
                enabledFirstPartyProviders: self.store.enabledFirstPartyProvidersForDisplay()).count > 1
        let plugins = Self.userPluginsForMenu(
            UserProviderPluginRegistry.all,
            isEnabled: self.settings.isPluginEnabled,
            topLevelSwitcherVisible: hasTopLevelSwitcher,
            selectedPluginID: selectedPluginID)
        guard !plugins.isEmpty else { return }
        if !menu.items.isEmpty, menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
        for (index, plugin) in plugins.enumerated() {
            menu.addItem(self.makeUserPluginMenuCardItem(plugin, width: width))
            if index < plugins.count - 1 {
                menu.addItem(.separator())
            }
        }
        menu.addItem(.separator())
    }

    func makeUserPluginMenuCardItem(
        _ plugin: UserProviderPlugin,
        width: CGFloat,
        id: String? = nil,
        onClick: (() -> Void)? = nil) -> NSMenuItem
    {
        let snapshot = self.store.snapshots[plugin.manifest.id]
        let error = self.store.errors[plugin.manifest.id]
        return self.makeMenuCardItem(
            UserPluginMenuCardView(
                plugin: plugin,
                snapshot: snapshot,
                error: error,
                isRefreshing: self.store.refreshingProviders.contains(plugin.manifest.id),
                showUsed: self.settings.usageBarsShowUsed,
                paceVisible: self.settings.paceVisible,
                resetStyle: self.settings.resetTimeDisplayStyle,
                width: width,
                onRefresh: { [weak self] in
                    self?.startManualRefresh(
                        for: plugin.manifest.id,
                        originatingMenuID: nil,
                        originatingMenuInteractionGeneration: nil)
                }),
            id: id ?? "pluginCard:\(plugin.manifest.id.rawValue)",
            width: width,
            heightCacheScope: plugin.manifest.id.rawValue,
            heightCacheFingerprint: UserPluginMenuCardView.fingerprint(
                snapshot: snapshot, error: error, resetStyle: self.settings.resetTimeDisplayStyle),
            containsInteractiveControls: true,
            onClick: onClick)
    }

    func refreshOpenMenusAfterUserPluginRefresh(_ instanceID: ProviderInstanceID) {
        self.invalidateMenus()
        guard self.isMenuRefreshEnabled else { return }
        let cardID = "pluginCard:\(instanceID.rawValue)"
        // Plugin cards capture snapshots, so their visible payload needs the guarded rebuild path.
        let overviewID = "\(Self.overviewRowIdentifierPrefix)\(instanceID.rawValue)"
        for menu in self.openMenus.values {
            (menu.items.first?.view as? ProviderSwitcherView)?.updateQuotaIndicators()
            if menu.items.contains(where: {
                let id = $0.representedObject as? String
                return id == cardID || id == overviewID
            }) {
                self.scheduleOpenMenuRebuildIfStillVisible(menu, provider: self.menuProvider(for: menu))
            }
        }
    }

    static func userPluginsForMenu(
        _ plugins: [UserProviderPlugin],
        isEnabled: (ProviderInstanceID) -> Bool,
        topLevelSwitcherVisible: Bool,
        selectedPluginID: ProviderInstanceID?) -> [UserProviderPlugin]
    {
        let enabledPlugins = plugins.filter { isEnabled($0.manifest.id) }
        if let selectedPluginID {
            let selected = enabledPlugins.filter { $0.manifest.id == selectedPluginID }
            let legacy = enabledPlugins.filter {
                !$0.manifest.topLevel && $0.manifest.id != selectedPluginID
            }
            return selected + legacy
        }
        return enabledPlugins.filter { !topLevelSwitcherVisible || !$0.manifest.topLevel }
    }

    func userPluginSwitcherIcon(for plugin: UserProviderPlugin) -> NSImage {
        Self.userPluginSwitcherIcon(
            for: plugin,
            snapshot: self.store.menuBarSnapshot(for: plugin.manifest.id),
            brandIcon: self.brandIcon)
    }

    static func userPluginSwitcherIcon(
        for plugin: UserProviderPlugin,
        snapshot: UsageSnapshot?,
        brandIcon: (UsageProvider) -> NSImage?) -> NSImage
    {
        if let provider = snapshot?.iconProvider, let image = brandIcon(provider) {
            return image
        }
        if let image = Self.userPluginSVGImage(plugin) {
            return image
        }
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let rawTint = plugin.manifest.icon.tint.dropFirst()
            let tint = UInt32(rawTint, radix: 16) ?? 0x6B7280
            NSColor(
                deviceRed: CGFloat((tint >> 16) & 0xFF) / 255,
                green: CGFloat((tint >> 8) & 0xFF) / 255,
                blue: CGFloat(tint & 0xFF) / 255,
                alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let monogram = plugin.manifest.icon.monogram as NSString
            let textSize = monogram.size(withAttributes: attributes)
            monogram.draw(
                at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The plugin's validated SVG as a template image, or nil when it has none or it does not decode.
    static func userPluginSVGImage(_ plugin: UserProviderPlugin) -> NSImage? {
        guard let svg = plugin.manifest.icon.svg,
              let source = NSImage(data: Data(svg.utf8)),
              source.size.width.isFinite, source.size.height.isFinite,
              source.size.width > 0, source.size.height > 0,
              source.size.width <= CGFloat(ProviderPluginIconSVG.maximumCanvasDimension),
              source.size.height <= CGFloat(ProviderPluginIconSVG.maximumCanvasDimension),
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: 32,
                  pixelsHigh: 32,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        let scale = 32 / max(source.size.width, source.size.height)
        guard scale.isFinite else { return nil }
        source.size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        let rect = NSRect(
            x: (32 - source.size.width) / 2,
            y: (32 - source.size.height) / 2,
            width: source.size.width,
            height: source.size.height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(NSRect(x: 0, y: 0, width: 32, height: 32))
        source.draw(in: rect)
        bitmap.size = NSSize(width: 16, height: 16)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }
}

struct UserPluginQuotaPresentation: Equatable {
    let title: String
    let percent: Double
    let text: String
    let resetText: String?

    static func make(
        title: String,
        window: RateWindow,
        showUsed: Bool,
        resetStyle: ResetTimeDisplayStyle,
        now: Date = Date()) -> Self
    {
        let used = min(100, max(0, window.usedPercent))
        let remaining = 100 - used
        return Self(
            title: window.title ?? L(title),
            percent: showUsed ? used : remaining,
            text: UsageFormatter.usageLine(remaining: remaining, used: used, showUsed: showUsed),
            resetText: UsageFormatter.resetLine(for: window, style: resetStyle, now: now))
    }
}

extension ProviderSwitcherView {
    static func pluginSwitcherImage(
        _ plugin: UserProviderPlugin,
        iconProvider: (UserProviderPlugin) -> NSImage) -> NSImage
    {
        let source = iconProvider(plugin)
        guard let image = source.copy() as? NSImage else { return source }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

struct UserPluginMenuCardView: View {
    let plugin: UserProviderPlugin
    let snapshot: UsageSnapshot?
    let error: String?
    let isRefreshing: Bool
    let showUsed: Bool
    var paceVisible: Bool = true
    let resetStyle: ResetTimeDisplayStyle
    let width: CGFloat
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Group {
                    if let image = StatusItemController.userPluginSVGImage(self.plugin) {
                        Image(nsImage: image).resizable().scaledToFit().padding(4)
                    } else {
                        Text(self.plugin.manifest.icon.monogram).font(.caption.bold())
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(self.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(self.plugin.manifest.name).font(.headline)
                    Text(self.plugin.fileURL.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if self.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: self.onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help(L("Refresh"))
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                if let snapshot {
                    Text(LastKnownUsagePresentation.message(capturedAt: snapshot.updatedAt))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let snapshot {
                self.window("Primary", snapshot.primary)
                self.window("Secondary", snapshot.secondary)
                self.window("Tertiary", snapshot.tertiary)
                if let cost = snapshot.providerCost {
                    HStack {
                        Text(cost.period ?? "Cost").foregroundStyle(.secondary)
                        Spacer()
                        Text(UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode))
                            .fontWeight(.medium)
                    }
                    .font(.caption)
                }
                if !snapshot.details.isEmpty {
                    Divider()
                    ProviderDetailSectionsContent(
                        sections: snapshot.details, chartColor: self.tint, paceVisible: self.paceVisible)
                }
                if let identity = snapshot.identity(for: self.plugin.manifest.id) {
                    self.identity(identity)
                }
            } else if self.error == nil {
                Text(L("No usage fetched yet")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 8)
        .frame(width: self.width, alignment: .leading)
    }

    @ViewBuilder
    private func identity(_ identity: ProviderIdentitySnapshot) -> some View {
        if identity.accountEmail != nil || identity.accountOrganization != nil || identity.loginMethod != nil
            || identity.accountID != nil
        {
            Divider()
            self.identityRow("Account", identity.accountEmail)
            self.identityRow("Organization", identity.accountOrganization)
            self.identityRow("Plan", identity.loginMethod)
            self.identityRow("Account ID", identity.accountID)
        }
    }

    @ViewBuilder
    private func identityRow(_ label: String, _ value: String?) -> some View {
        if let value {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).fontWeight(.medium).textSelection(.enabled)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func window(_ title: String, _ window: RateWindow?) -> some View {
        if let window {
            let presentation = UserPluginQuotaPresentation.make(
                title: title,
                window: window,
                showUsed: self.showUsed,
                resetStyle: self.resetStyle)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(presentation.title).foregroundStyle(.secondary)
                    Spacer()
                    Text(presentation.text).monospacedDigit()
                }
                .font(.caption)
                UsageProgressBar(
                    percent: presentation.percent,
                    tint: self.tint,
                    accessibilityLabel: presentation.title)
                if let reset = presentation.resetText {
                    Text(reset).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tint: Color {
        let color = ProviderColor(hexString: self.plugin.manifest.icon.tint) ?? ProviderColor(hex: 0x6B7280)
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    static func fingerprint(
        snapshot: UsageSnapshot?, error: String?, resetStyle: ResetTimeDisplayStyle, now: Date = .now) -> String
    {
        let resets = [snapshot?.primary, snapshot?.secondary, snapshot?.tertiary].map { window in
            window.flatMap { UsageFormatter.resetLine(for: $0, style: resetStyle, now: now) } ?? ""
        }
        return ([
            codexBarLocalizationSignature(),
            snapshot?.updatedAt.timeIntervalSinceReferenceDate.description ?? "none",
            String(snapshot?.details.count ?? 0),
            snapshot?.primary?.title ?? "",
            snapshot?.secondary?.title ?? "",
            snapshot?.tertiary?.title ?? "",
            error ?? "",
            error == nil ? "" : snapshot.map {
                LastKnownUsagePresentation.message(capturedAt: $0.updatedAt, now: now)
            } ?? "",
        ] + resets).joined(separator: "|")
    }
}
#endif
