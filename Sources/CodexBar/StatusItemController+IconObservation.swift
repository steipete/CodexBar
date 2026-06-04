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
            providerSignatures = [
                self.providerStoreIconObservationSignature(for: primary, showBrandPercent: showBrandPercent),
                "mergedStatus=\(self.mergedIconStatusIndicator().rawValue)",
            ].joined(separator: "||")
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
            "iconStyle=\(String(describing: self.store.iconStyle))",
            "showUsed=\(self.settings.usageBarsShowUsed ? "1" : "0")",
            "brandPercent=\(showBrandPercent ? "1" : "0")",
            "needsAnimation=\(self.needsMenuBarIconAnimation() ? "1" : "0")",
            providerSignatures,
        ].joined(separator: "|")
    }

    private func providerStoreIconObservationSignature(for provider: UsageProvider, showBrandPercent: Bool) -> String {
        let snapshot = self.store.snapshot(for: provider)
        let style = self.store.style(for: provider)
        let resolved = snapshot.map {
            IconRemainingResolver.resolvedPercents(
                snapshot: $0,
                style: style,
                showUsed: self.settings.usageBarsShowUsed)
        }
        let creditsRemaining = self.menuBarCreditsRemainingForIcon(provider: provider, snapshot: snapshot)
        let displayText = showBrandPercent ? self.menuBarDisplayText(for: provider, snapshot: snapshot) : nil

        return [
            provider.rawValue,
            "style=\(String(describing: style))",
            "primary=\(Self.iconSignatureValue(resolved?.primary))",
            "weekly=\(Self.iconSignatureValue(resolved?.secondary))",
            "credits=\(Self.iconSignatureValue(creditsRemaining))",
            "stale=\(self.store.isStale(provider: provider) ? "1" : "0")",
            "status=\(self.store.statusIndicator(for: provider).rawValue)",
            "anim=\(self.shouldAnimate(provider: provider) ? "1" : "0")",
            "refreshing=\(self.store.refreshingProviders.contains(provider) ? "1" : "0")",
            "text=\(displayText ?? "nil")",
        ].joined(separator: "|")
    }

    private func mergedIconStatusIndicator() -> ProviderStatusIndicator {
        for provider in self.store.enabledProvidersForDisplay() {
            let indicator = self.store.statusIndicator(for: provider)
            if indicator.hasIssue { return indicator }
        }
        return .none
    }
}
