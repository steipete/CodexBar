import CodexBarCore

extension StatusItemController {
    func synchronizeFrontmostProviderMonitor() {
        let shouldMonitor = FrontmostProviderMonitoringPolicy.shouldRun(
            source: self.settings.unifiedIconSource,
            mergeIcons: self.shouldMergeIcons,
            isStacked: self.stackedMergeIconProvidersIfActive() != nil)
        guard shouldMonitor else {
            self.frontmostProviderMonitor?.synchronize(shouldRun: false)
            self.frontmostProviderMonitor = nil
            return
        }

        if self.frontmostProviderMonitor == nil {
            self.frontmostProviderMonitor = FrontmostProviderMonitor(
                source: WorkspaceFrontmostApplicationEventSource(),
                enabledProviders: { [weak self] in
                    guard let self else { return [] }
                    return Set(self.store.enabledFirstPartyProvidersForDisplay())
                },
                onChange: { [weak self] _ in
                    guard let self, !self.hasPreparedForAppShutdown else { return }
                    self.updateIcons()
                })
        }
        self.frontmostProviderMonitor?.synchronize(shouldRun: true)
    }
}
