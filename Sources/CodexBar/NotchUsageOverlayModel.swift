import CodexBarCore
import SwiftUI

struct NotchUsageOverlayModel: Equatable {
    struct Bar: Equatable {
        let title: String
        let percent: Double
        let percentText: String
        let resetText: String?
        let accessibilityLabel: String
    }

    struct ProviderRow: Equatable, Identifiable {
        let id: ProviderInstanceID
        let name: String
        let tint: Color
        let bars: [Bar]
        let statusText: String?

        /// VoiceOver summary for the whole tile. The tile is one combined accessibility element,
        /// so the label has to carry the bar details itself — overriding it with just the name
        /// would silence every usage figure.
        var accessibilitySummary: String {
            var parts = [self.name]
            if let statusText = self.statusText {
                parts.append(statusText)
            }
            parts.append(contentsOf: self.bars.map(\.accessibilityLabel))
            return parts.joined(separator: ", ")
        }
    }

    struct SessionRow: Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String
        let isActive: Bool
    }

    /// The agent-session list, rendered as a full-width band above or below the provider grid.
    /// Never a tile in the grid, so it cannot appear in ``items`` by construction.
    struct SessionsBand: Equatable {
        let title: String
        let rows: [SessionRow]
    }

    /// Provider tiles, in display order.
    let items: [ProviderRow]
    var columnCount: Int = 1
    /// True when every tile in a grid row should be as tall as the tallest tile in that row.
    var matchesRowHeights: Bool = false
    /// The session list, when it is switched on.
    var sessionsBand: SessionsBand?
    /// Which side of the grid the band sits on; ignored when `sessionsBand` is nil.
    var sessionsAbove = false

    /// Round-robin placement shared by the tile grid and the full-width session band: element `i`
    /// goes to column `i % count`, so reading across a row follows list order.
    static func distribute<T>(_ elements: [T], into count: Int) -> [[T]] {
        let count = max(count, 1)
        var columns = Array(repeating: [T](), count: count)
        for (index, element) in elements.enumerated() {
            columns[index % count].append(element)
        }
        return columns
    }

    /// Tiles flow into the columns in list order, left to right then down, so reordering in
    /// settings moves a tile predictably and no column is left short by a balancing heuristic.
    func columns() -> [[ProviderRow]] {
        Self.distribute(self.items, into: self.columnCount)
    }

    /// The same placement as ``columns()``, sliced the other way: element `r` holds the tiles that
    /// share grid row `r`. Only the last row can be short.
    func rows() -> [[ProviderRow]] {
        let count = max(self.columnCount, 1)
        return stride(from: 0, to: self.items.count, by: count).map { start in
            Array(self.items[start..<min(start + count, self.items.count)])
        }
    }

    static func bars(
        snapshot: UsageSnapshot,
        labels: ProviderRateWindowLabels?,
        showUsed: Bool,
        now: Date = .now) -> [Bar]
    {
        var bars: [Bar] = []
        bars.reserveCapacity(4)

        if let primary = snapshot.primary {
            bars.append(self.makeBar(
                title: labels.map { L($0.primary) } ?? L("metric_pref_primary"),
                window: primary,
                showUsed: showUsed))
        }
        if let secondary = snapshot.secondary {
            bars.append(self.makeBar(
                title: labels.map { L($0.secondary) } ?? L("metric_pref_secondary"),
                window: secondary,
                showUsed: showUsed))
        }
        if let tertiary = snapshot.tertiary {
            bars.append(self.makeBar(
                title: labels.map { L($0.tertiary) } ?? L("metric_pref_tertiary"),
                window: tertiary,
                showUsed: showUsed))
        }
        if let extra = snapshot.extraRateWindows?.first(where: \.usageKnown) {
            bars.append(self.makeBar(
                title: L(extra.title),
                window: extra.window,
                showUsed: showUsed))
        } else if let cost = snapshot.providerCost, cost.limit > 0 {
            bars.append(self.makeCostBar(cost: cost, showUsed: showUsed))
        }

        return Array(bars.prefix(4))
    }

    @MainActor
    static func make(
        store: UsageStore,
        settings: SettingsStore,
        agentSessions: AgentSessionsStore? = nil,
        now: Date = .now) -> Self
    {
        let showUsed = settings.usageBarsShowUsed
        var providerRows: [ProviderInstanceID: ProviderRow] = [:]
        var availableKeys: [String] = []

        for instanceID in store.enabledProvidersForDisplay()
            where settings.isNotchProviderVisible(instanceID)
        {
            guard let row = self.providerRow(
                instanceID: instanceID,
                store: store,
                settings: settings,
                showUsed: showUsed,
                now: now)
            else { continue }
            providerRows[instanceID] = row
            availableKeys.append(instanceID.rawValue)
        }

        var sessionsBand: SessionsBand?
        if settings.notchShowsAgentSessions, settings.agentSessionsEnabled, let agentSessions {
            sessionsBand = SessionsBand(
                title: L("Agent Sessions"),
                rows: self.sessionRows(
                    agentSessions: agentSessions,
                    labelStyle: settings.agentSessionLabelStyle,
                    now: now))
        }

        let items: [ProviderRow] = settings.notchOrderedItemKeys(availableKeys).compactMap { key in
            guard let instanceID = ProviderInstanceID(rawValue: key) else { return nil }
            return providerRows[instanceID]
        }

        return Self(
            items: items,
            columnCount: settings.notchColumnCount,
            matchesRowHeights: settings.notchMatchesRowHeights,
            sessionsBand: sessionsBand,
            sessionsAbove: settings.notchSessionsPlacement == .above)
    }

    @MainActor
    private static func providerRow(
        instanceID: ProviderInstanceID,
        store: UsageStore,
        settings: SettingsStore,
        showUsed: Bool,
        now: Date) -> ProviderRow?
    {
        if let provider = instanceID.firstPartyProvider {
            let snapshot = store.presentationSnapshot(for: provider)
            let labels = snapshot.map { snapshot in
                ProviderDescriptorRegistry.descriptor(for: provider).presentation.rateWindowLabels(
                    metadata: store.metadata(for: provider),
                    snapshot: snapshot,
                    now: now)
            }
            var bars = snapshot.map {
                self.bars(snapshot: $0, labels: labels, showUsed: showUsed, now: now)
            } ?? []
            let fallbackSlotFilled = snapshot.map(Self.hasOtherBar) ?? false
            // Provider-specific by design: the fourth-bar fallback to monthly credits reads the
            // Codex-only global credits snapshot; no other provider publishes an equivalent.
            if provider == .codex,
               !fallbackSlotFilled,
               bars.count < 4,
               let creditLimit = store.credits?.codexCreditLimit
            {
                bars.append(self.makeCreditBar(creditLimit: creditLimit, showUsed: showUsed, now: now))
            }
            return ProviderRow(
                id: instanceID,
                name: store.metadata(for: provider).displayName,
                tint: UsageMenuCardView.Model.progressColor(for: provider),
                bars: Array(bars.prefix(4)),
                statusText: self.statusText(bars: bars, error: store.errors[instanceID]))
        }

        // User-provider plugins are macOS-only in the app target. Keep this branch guarded so the
        // model remains source-compatible with builds that do not provide JavaScriptCore.
        #if canImport(JavaScriptCore)
        // `enabledProvidersForDisplay()` already filters on the same enablement flag, so the only
        // real filter here is the registry lookup: a plugin can be enabled but no longer loaded.
        guard let plugin = UserProviderPluginRegistry.plugin(for: instanceID) else { return nil }
        let bars = store.snapshots[instanceID].map {
            self.bars(snapshot: $0, labels: nil, showUsed: showUsed, now: now)
        } ?? []
        return ProviderRow(
            id: instanceID,
            name: plugin.manifest.name,
            tint: Self.pluginTint(plugin),
            bars: bars,
            statusText: self.statusText(bars: bars, error: store.errors[instanceID]))
        #else
        return nil
        #endif
    }

    @MainActor
    private static func sessionRows(
        agentSessions: AgentSessionsStore,
        labelStyle: AgentSessionLabelStyle,
        now: Date) -> [SessionRow]
    {
        let local = agentSessions.localSessions.map { session in
            self.sessionRow(session, host: nil, labelStyle: labelStyle, now: now)
        }
        let remote = agentSessions.remoteHosts.flatMap { host in
            host.sessions.map { session in
                self.sessionRow(session, host: host.host, labelStyle: labelStyle, now: now)
            }
        }
        return local + remote
    }

    private static func sessionRow(
        _ session: AgentSession,
        host: String?,
        labelStyle: AgentSessionLabelStyle,
        now: Date) -> SessionRow
    {
        var detailParts = [session.dialect?.rawValue ?? session.provider.rawValue]
        if let host {
            detailParts.append(host)
        }
        detailParts.append(self.sessionAge(session, now: now))
        return SessionRow(
            id: [host, session.id].compactMap(\.self).joined(separator: "@"),
            title: labelStyle.label(for: session),
            detail: detailParts.joined(separator: " · "),
            isActive: session.state == .active)
    }

    private static func sessionAge(_ session: AgentSession, now: Date) -> String {
        guard let activity = session.lastActivityAt ?? session.startedAt else { return L("now") }
        let seconds = max(0, Int(now.timeIntervalSince(activity)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    /// The label mirrors exactly what the row shows — title, percentage line, and reset/cost text.
    /// The tile is one combined accessibility element, so this is the only route the visible
    /// figures have to VoiceOver; a bare "<title> usage" label would silence all of them.
    private static func accessibilityLabel(title: String, percentText: String, resetText: String?) -> String {
        var parts = [title, percentText]
        if let resetText {
            parts.append(resetText)
        }
        return parts.joined(separator: ", ")
    }

    private static func makeBar(title: String, window: RateWindow, showUsed: Bool) -> Bar {
        let used = Self.clampedPercent(window.usedPercent)
        let remaining = 100 - used
        // Some providers describe the window itself (e.g. "5-hour"), which is already the row title here.
        let resetText = window.resetDescription.flatMap { $0 == title ? nil : $0 }
        let percentText = UsageFormatter.usageLine(remaining: remaining, used: used, showUsed: showUsed)
        return Bar(
            title: title,
            percent: showUsed ? used : remaining,
            percentText: percentText,
            resetText: resetText,
            accessibilityLabel: Self.accessibilityLabel(
                title: title, percentText: percentText, resetText: resetText))
    }

    /// Matches the mutually-exclusive "other" projection in ``bars``: the first known named
    /// window wins, otherwise valid provider spend wins. Credits may fill the slot only when both
    /// are absent.
    private static func hasOtherBar(_ snapshot: UsageSnapshot) -> Bool {
        if snapshot.extraRateWindows?.contains(where: \.usageKnown) == true {
            return true
        }
        return snapshot.providerCost.map { $0.limit > 0 } == true
    }

    private static func makeCostBar(cost: ProviderCostSnapshot, showUsed: Bool) -> Bar {
        let used = Self.clampedPercent(cost.used / cost.limit * 100)
        let remaining = 100 - used
        let title = L(cost.period ?? "Cost")
        let percentText = UsageFormatter.usageLine(remaining: remaining, used: used, showUsed: showUsed)
        let resetText = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
        return Bar(
            title: title,
            percent: showUsed ? used : remaining,
            percentText: percentText,
            resetText: resetText,
            accessibilityLabel: Self.accessibilityLabel(
                title: title, percentText: percentText, resetText: resetText))
    }

    private static func makeCreditBar(
        creditLimit: CodexCreditLimitSnapshot,
        showUsed: Bool,
        now: Date) -> Bar
    {
        let used = Self.clampedPercent(creditLimit.usedPercent)
        let remaining = 100 - used
        let title = L(creditLimit.title)
        let percentText = UsageFormatter.usageLine(remaining: remaining, used: used, showUsed: showUsed)
        let resetText = creditLimit.resetsAt.flatMap {
            UsageFormatter.resetLine(
                for: RateWindow(usedPercent: used, windowMinutes: nil, resetsAt: $0, resetDescription: nil),
                style: .countdown,
                now: now)
        }
        return Bar(
            title: title,
            percent: showUsed ? used : remaining,
            percentText: percentText,
            resetText: resetText,
            accessibilityLabel: Self.accessibilityLabel(
                title: title, percentText: percentText, resetText: resetText))
    }

    private static func clampedPercent(_ percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return min(100, max(0, percent))
    }

    private static func statusText(bars: [Bar], error: String?) -> String? {
        guard bars.isEmpty else { return nil }
        return error ?? L("No usage fetched yet")
    }

    #if canImport(JavaScriptCore)
    private static func pluginTint(_ plugin: UserProviderPlugin) -> Color {
        let raw = plugin.manifest.icon.tint.dropFirst()
        let value = UInt32(raw, radix: 16) ?? 0x6B7280
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
    #endif
}
