import CodexBarCore
import Foundation

extension StatusItemController {
    func storeIconObservationSignature() -> String {
        let showBrandPercent = self.settings.menuBarShowsBrandIconWithPercent
        let mergeIcons = self.shouldMergeIcons
        let visibleProviders = self.store.enabledProvidersForDisplay().map(\.rawValue).sorted().joined(separator: ",")
        let providerSignatures: String
        let primaryProvider: UsageProvider?
        if mergeIcons {
            let primary = self.primaryProviderForUnifiedIcon()
            primaryProvider = primary
            providerSignatures = self.providerStoreIconObservationSignature(
                for: primary,
                showBrandPercent: showBrandPercent)
        } else {
            primaryProvider = nil
            providerSignatures = UsageProvider.allCases
                .filter { self.isVisible($0) }
                .map { self.providerStoreIconObservationSignature(for: $0, showBrandPercent: showBrandPercent) }
                .joined(separator: "||")
        }
        return [
            "merge=\(mergeIcons ? "1" : "0")",
            "visible=\(visibleProviders)",
            "primary=\(primaryProvider?.rawValue ?? "nil")",
            "iconStyle=\(self.store.iconStyle.rawValue)",
            "showUsed=\(self.settings.usageBarsShowUsed ? "1" : "0")",
            "brandPercent=\(showBrandPercent ? "1" : "0")",
            "hideCritters=\(self.settings.menuBarHidesCritters ? "1" : "0")",
            "needsAnimation=\(self.needsMenuBarIconAnimation() ? "1" : "0")",
            providerSignatures,
        ].joined(separator: "|")
    }

    private func providerStoreIconObservationSignature(for provider: UsageProvider, showBrandPercent: Bool) -> String {
        let snapshot = self.store.snapshot(for: provider)
        let style = self.store.style(for: provider)
        let resolved = self.resolvedMenuBarIconPercents(
            provider: provider,
            snapshot: snapshot,
            style: style,
            showUsed: self.settings.usageBarsShowUsed)
        let creditsRemaining = self.menuBarCreditsRemainingForIcon(provider: provider, snapshot: snapshot)
        let displayText = showBrandPercent ? self.menuBarDisplayText(for: provider, snapshot: snapshot) : nil
        let layoutCostSignature = showBrandPercent
            ? self.storedMenuBarLayoutCostSignature(for: provider)
            : nil
        let layoutPaceSignature = showBrandPercent
            ? self.storedMenuBarLayoutPaceSignature(for: provider, snapshot: snapshot)
            : nil

        return [
            provider.rawValue,
            "style=\(style.rawValue)",
            "primary=\(Self.iconSignatureValue(resolved?.primary))",
            "weekly=\(Self.iconSignatureValue(resolved?.secondary))",
            "credits=\(Self.iconSignatureValue(creditsRemaining))",
            "stale=\(self.store.isStale(provider: provider) ? "1" : "0")",
            "status=\(self.store.statusIndicator(for: provider).rawValue)",
            "anim=\(self.shouldAnimate(provider: provider) ? "1" : "0")",
            "refreshing=\(self.store.refreshingProviders.contains(provider) ? "1" : "0")",
            "text=\(displayText ?? "nil")",
            "layoutCost=\(layoutCostSignature ?? "nil")",
            "layoutPace=\(layoutPaceSignature ?? "nil")",
        ].joined(separator: "|")
    }

    private func storedMenuBarLayoutPaceSignature(for provider: UsageProvider, snapshot: UsageSnapshot?) -> String? {
        let resolution = self.settings.menuBarLayoutResolution(for: provider)
        guard !resolution.usesLegacyRendering else { return nil }

        let tokens = resolution.layout.lines.joined()
        let showsRunsOut = tokens.contains(.runsOut)
        let showsPacePercent = tokens.contains(.pacePercent)
        guard showsRunsOut || showsPacePercent else { return nil }

        let now = Date()
        let windows = self.menuBarLayoutWindows(provider: provider, snapshot: snapshot, now: now)
        let paceWindow = windows.weekly ?? windows.automatic
        let pace = paceWindow
            .flatMap { self.store.weeklyPace(provider: provider, window: $0, now: now) }
        let runsOut = pace
            .flatMap { UsagePaceText.weeklyDetail(provider: provider, pace: $0, now: now).rightLabel }
        let pacePercent = pace
            .flatMap { MenuBarDisplayText.paceText(pace: $0) }

        return [
            "runsOut=\(showsRunsOut ? runsOut ?? "nil" : "unused")",
            "pacePercent=\(showsPacePercent ? pacePercent ?? "nil" : "unused")",
        ].joined(separator: ",")
    }

    private func storedMenuBarLayoutCostSignature(for provider: UsageProvider) -> String? {
        let resolution = self.settings.menuBarLayoutResolution(for: provider)
        guard !resolution.usesLegacyRendering else { return nil }

        let tokens = resolution.layout.lines.joined()
        let showsToday = tokens.contains(.costToday)
        let showsLast30Days = tokens.contains(.cost30d)
        guard showsToday || showsLast30Days else { return nil }

        let costs = self.menuBarLayoutCostStrings(provider: provider)
        return [
            "today=\(showsToday ? costs.today ?? "nil" : "unused")",
            "last30Days=\(showsLast30Days ? costs.last30Days ?? "nil" : "unused")",
        ].joined(separator: ",")
    }
}
