import AppKit
import CodexBarCore

extension StatusItemController {
    func refreshProviderSelectionDependentUI(
        refreshOpenMenus: Bool = false,
        deferRendering: Bool = false)
    {
        #if DEBUG
        guard !self.isReleasedForTesting else { return }
        #endif
        self.advanceMenuInteraction(for: self.mergedMenu)
        self.invalidateMenus(refreshOpenMenus: refreshOpenMenus)
        if deferRendering {
            self.scheduleProviderSelectionUIRefresh()
            return
        }
        self.refreshProviderSelectionRendering()
    }

    private func scheduleProviderSelectionUIRefresh() {
        self.providerSelectionUIRefreshTask?.cancel()
        self.providerSelectionUIRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.refreshProviderSelectionRendering()
            self.providerSelectionUIRefreshTask = nil
        }
    }

    private func refreshProviderSelectionRendering() {
        self.updateAnimationState()
        self.updateBlinkingState()
        let phase: Double? = self.activeLoadingAnimationPhase()
        self.applyIcon(phase: phase)
    }

    func navigateProviderSwitcher(
        _ direction: StatusItemMenuProviderNavigationDirection,
        menu: NSMenu? = nil)
    {
        guard self.shouldMergeIcons else { return }
        let enabledProviders = self.store.enabledFirstPartyProvidersForDisplay()
        let switcherProviderIDs = self.switcherProviderIDs(enabledFirstPartyProviders: enabledProviders)
        guard switcherProviderIDs.count > 1 else { return }

        let includesOverview = self.includesOverviewTab(enabledProviders: enabledProviders)
        var selections = switcherProviderIDs.map { ProviderSwitcherSelection.provider($0) }
        if includesOverview {
            selections.insert(.overview, at: 0)
        }

        let current = self.resolvedSwitcherSelection(
            enabledProviders: enabledProviders,
            includesOverview: includesOverview)
        guard let currentIndex = selections.firstIndex(of: current) else { return }

        let delta = direction == .next ? 1 : -1
        let nextIndex = (currentIndex + delta + selections.count) % selections.count
        let selection = selections[nextIndex]
        let menuProvider: UsageProvider? = switch selection {
        case .overview:
            self.navigationResolvedProvider(enabledProviders: enabledProviders) ?? .codex
        case let .provider(instanceID):
            instanceID.firstPartyProvider
        }
        self.preservingMergedSwitcherContentCachesDuringInvalidation {
            switch selection {
            case .overview:
                self.settings.mergedMenuLastSelectedWasOverview = true
                self.lastMenuProvider =
                    (self.navigationResolvedProvider(enabledProviders: enabledProviders) ?? .codex).instanceID
            case let .provider(provider):
                self.settings.mergedMenuLastSelectedWasOverview = false
                self.selectedMenuProvider = provider
                self.lastMenuProvider = provider
            }
            self.lastMergedSwitcherSelection = selection
            self.refreshProviderSelectionDependentUI(deferRendering: true)
        }
        let trackedMenu = menu ?? self.providerSwitcherShortcutMenuID.flatMap { self.openMenus[$0] }
        if let trackedMenu {
            self.requestProviderSwitcherMenuRebuild(
                trackedMenu,
                provider: menuProvider)
        }
    }

    private func navigationResolvedProvider(enabledProviders: [UsageProvider]) -> UsageProvider? {
        if enabledProviders.isEmpty {
            return .codex
        }
        if let selected = self.selectedMenuProvider?.firstPartyProvider, enabledProviders.contains(selected) {
            return selected
        }
        return enabledProviders.first(where: { self.store.isProviderAvailable($0) }) ?? enabledProviders.first
    }
}
