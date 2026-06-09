import CodexBarCore

extension StatusItemController {
    func refreshProviderSelectionDependentUI(
        refreshOpenMenus: Bool = false,
        deferRendering: Bool = false)
    {
        #if DEBUG
        guard !self.isReleasedForTesting else { return }
        #endif
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
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            self.refreshProviderSelectionRendering()
            self.providerSelectionUIRefreshTask = nil
        }
    }

    private func refreshProviderSelectionRendering() {
        self.updateAnimationState()
        self.updateBlinkingState()
        let phase: Double? = self.needsMenuBarIconAnimation() ? self.animationPhase : nil
        self.applyIcon(phase: phase)
    }

    func navigateProviderSwitcher(_ direction: StatusItemMenuProviderNavigationDirection) {
        guard self.shouldMergeIcons else { return }
        let enabledProviders = self.store.enabledProvidersForDisplay()
        guard enabledProviders.count > 1 else { return }

        let includesOverview = !self.settings.resolvedMergedOverviewProviders(
            activeProviders: enabledProviders,
            maxVisibleProviders: SettingsStore.mergedOverviewProviderLimit).isEmpty
        var selections = enabledProviders.map(ProviderSwitcherSelection.provider)
        if includesOverview {
            selections.insert(.overview, at: 0)
        }

        let current: ProviderSwitcherSelection = if includesOverview,
                                                    self.settings.mergedMenuLastSelectedWasOverview
        {
            .overview
        } else {
            .provider(self.navigationResolvedProvider(enabledProviders: enabledProviders) ?? .codex)
        }
        guard let currentIndex = selections.firstIndex(of: current) else { return }

        let delta = direction == .next ? 1 : -1
        let nextIndex = (currentIndex + delta + selections.count) % selections.count
        let selection = selections[nextIndex]
        self.preservingMergedSwitcherContentCachesDuringInvalidation {
            switch selection {
            case .overview:
                self.settings.mergedMenuLastSelectedWasOverview = true
                self.lastMenuProvider = self.navigationResolvedProvider(enabledProviders: enabledProviders) ?? .codex
            case let .provider(provider):
                self.settings.mergedMenuLastSelectedWasOverview = false
                self.selectedMenuProvider = provider
                self.lastMenuProvider = provider
            }
            self.lastMergedSwitcherSelection = selection
            self.refreshProviderSelectionDependentUI(refreshOpenMenus: true, deferRendering: true)
        }
    }

    private func navigationResolvedProvider(enabledProviders: [UsageProvider]) -> UsageProvider? {
        if enabledProviders.isEmpty { return .codex }
        if let selected = self.selectedMenuProvider, enabledProviders.contains(selected) {
            return selected
        }
        return enabledProviders.first(where: { self.store.isProviderAvailable($0) }) ?? enabledProviders.first
    }
}
