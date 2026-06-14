import CodexBarCore
import Foundation

enum CodexMenuBarMetricAverage {
    static func averageWindow(active: RateWindow?, imported: [RateWindow]) -> RateWindow? {
        let windows = [active].compactMap(\.self) + imported
        guard !windows.isEmpty else { return nil }
        guard windows.count > 1 else { return windows[0] }

        let usedPercent = windows.map(\.usedPercent).reduce(0, +) / Double(windows.count)
        return RateWindow(usedPercent: usedPercent, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
    }
}

@MainActor
extension UsageStore {
    func codexMenuBarMetricWindowIncludingImported(activeSnapshot: UsageSnapshot?) -> RateWindow? {
        let importedWindows = self.importedCodexMenuBarMetricWindows()
        guard !importedWindows.isEmpty else {
            return MenuBarMetricWindowResolver.rateWindow(
                preference: self.settings.menuBarMetricPreference(for: .codex, snapshot: activeSnapshot),
                provider: .codex,
                snapshot: activeSnapshot,
                supportsAverage: self.settings.menuBarMetricSupportsAverage(for: .codex))
        }

        let activeWindow = self.codexMenuBarMetricWindow(snapshot: activeSnapshot, includeLiveAdjuncts: true)
        return CodexMenuBarMetricAverage.averageWindow(active: activeWindow, imported: importedWindows)
    }

    func menuBarIconPercents(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        style: IconStyle,
        showUsed: Bool)
        -> (primary: Double?, secondary: Double?)
    {
        if provider == .codex {
            let importedWindows = self.importedCodexMenuBarMetricWindows()
            if !importedWindows.isEmpty,
               let window = CodexMenuBarMetricAverage.averageWindow(
                   active: self.codexMenuBarMetricWindow(snapshot: snapshot, includeLiveAdjuncts: true),
                   imported: importedWindows)
            {
                return (
                    primary: showUsed ? window.usedPercent : window.remainingPercent,
                    secondary: nil)
            }
        }

        guard let snapshot else { return (primary: nil, secondary: nil) }
        return IconRemainingResolver.resolvedPercents(
            snapshot: snapshot,
            style: style,
            showUsed: showUsed)
    }

    func importedCodexMenuBarMetricWindows() -> [RateWindow] {
        self.importedCodexAccountSnapshots.compactMap { imported in
            self.codexMenuBarMetricWindow(snapshot: imported.snapshot, includeLiveAdjuncts: false)
        }
    }

    func codexMenuBarMetricWindow(
        snapshot: UsageSnapshot?,
        includeLiveAdjuncts: Bool)
        -> RateWindow?
    {
        guard let snapshot else { return nil }
        let projection = self.codexMenuBarProjection(snapshot: snapshot, includeLiveAdjuncts: includeLiveAdjuncts)
        return Self.codexMenuBarMetricWindow(
            projection: projection,
            preference: self.settings.menuBarMetricPreference(for: .codex, snapshot: snapshot),
            supportsAverage: self.settings.menuBarMetricSupportsAverage(for: .codex))
    }

    private func codexMenuBarProjection(
        snapshot: UsageSnapshot,
        includeLiveAdjuncts: Bool)
        -> CodexConsumerProjection
    {
        CodexConsumerProjection.make(
            surface: .menuBar,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: includeLiveAdjuncts ? self.credits : nil,
                rawCreditsError: includeLiveAdjuncts ? self.lastCreditsError : nil,
                liveDashboard: includeLiveAdjuncts ? self.openAIDashboard : nil,
                rawDashboardError: includeLiveAdjuncts ? self.lastOpenAIDashboardError : nil,
                dashboardAttachmentAuthorized: includeLiveAdjuncts
                    ? self.openAIDashboardAttachmentAuthorized
                    : false,
                dashboardRequiresLogin: includeLiveAdjuncts
                    ? self.openAIDashboardRequiresLogin
                    : false,
                now: snapshot.updatedAt))
    }

    private static func codexMenuBarMetricWindow(
        projection: CodexConsumerProjection,
        preference: MenuBarMetricPreference,
        supportsAverage: Bool)
        -> RateWindow?
    {
        let lanes = projection.visibleRateLanes
        let first = lanes.first.flatMap { projection.rateWindow(for: $0) }
        let second = lanes.dropFirst().first.flatMap { projection.rateWindow(for: $0) }

        switch preference {
        case .secondary, .tertiary:
            return second ?? first
        case .extraUsage:
            return first
        case .average:
            guard supportsAverage,
                  let primary = first,
                  let secondary = second
            else {
                return first
            }
            let usedPercent = (primary.usedPercent + secondary.usedPercent) / 2
            return RateWindow(
                usedPercent: usedPercent,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil)
        case .automatic, .primary:
            return first
        }
    }
}
