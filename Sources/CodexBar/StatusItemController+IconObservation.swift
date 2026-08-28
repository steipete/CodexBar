import CodexBarCore
import Foundation

extension StatusItemController {
    func observeStoreIconChanges() {
        withObservationTracking {
            _ = self.store.iconObservationToken
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeStoreIconChanges()
                let signature = self.storeIconObservationSignature()
                guard signature != self.lastObservedStoreIconWorkSignature else { return }
                self.lastObservedStoreIconWorkSignature = signature
                self.updateIcons()
            }
        }
    }

    func storeIconObservationSignature() -> String {
        let showBrandPercent = self.settings.menuBarShowsBrandIconWithPercent
        let mergeIcons = self.shouldMergeIcons
        let needsAnimation = self.needsMenuBarIconAnimation()
        let providerSignatures = UsageProvider.allCases.map {
            self.providerStoreIconObservationSignature(for: $0, showBrandPercent: showBrandPercent)
        }.joined(separator: "||")
        let accountSignatures = self.accountStoreIconObservationSignature()
        let visibleProviders = self.store.enabledProvidersForDisplay().map(\.rawValue).sorted().joined(separator: ",")
        return [
            "merge=\(mergeIcons ? "1" : "0")",
            "visible=\(visibleProviders)",
            "iconStyle=\(String(describing: self.store.iconStyle))",
            "brandPercent=\(showBrandPercent ? "1" : "0")",
            "needsAnimation=\(needsAnimation ? "1" : "0")",
            providerSignatures,
            accountSignatures,
        ].joined(separator: "|")
    }

    private func providerStoreIconObservationSignature(
        for provider: UsageProvider,
        showBrandPercent: Bool) -> String
    {
        let snapshot = self.store.snapshot(for: provider)
        let stale = self.store.isStale(provider: provider)
        let status = self.store.statusIndicator(for: provider).rawValue
        let isVisibleForAnimation = self.shouldMergeIcons ? self.isEnabled(provider) : self.isVisible(provider)
        let isAnimating = isVisibleForAnimation && !stale && snapshot == nil
        let isRefreshingWarpPlaceholder = self.store.refreshingProviders.contains(provider)
        let creditsRemaining = provider == .codex
            ? self.store.codexMenuBarCreditsRemaining(
                snapshotOverride: snapshot,
                now: snapshot?.updatedAt ?? Date())
            : nil
        let displayText = showBrandPercent ? self.menuBarDisplayText(for: provider, snapshot: snapshot) : nil

        return [
            provider.rawValue,
            "style=\(String(describing: self.store.style(for: provider)))",
            "snapshot=\(String(describing: snapshot))",
            "stale=\(stale ? "1" : "0")",
            "status=\(status)",
            "anim=\(isAnimating ? "1" : "0")",
            "refreshing=\(isRefreshingWarpPlaceholder ? "1" : "0")",
            "credits=\(String(describing: creditsRemaining))",
            "text=\(displayText ?? "nil")",
        ].joined(separator: "|")
    }

    private func accountStoreIconObservationSignature() -> String {
        let tokenSignatures = self.store.accountSnapshots
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { provider, snapshots in
                snapshots.map {
                    "\(provider.rawValue):\($0.id):\(String(describing: $0.snapshot)):\($0.error ?? "")"
                }
            }
        let codexSignatures = self.store.codexAccountSnapshots.map {
            "codex:\($0.id):\(String(describing: $0.snapshot)):\($0.error ?? "")"
        }
        return (tokenSignatures + codexSignatures).joined(separator: "||")
    }
}
