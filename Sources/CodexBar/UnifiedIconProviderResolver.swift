import CodexBarCore

struct UnifiedIconContext: Equatable, Sendable {
    let source: UnifiedIconSource
    let focusedProvider: UsageProvider?
    let isMergedMenuOpen: Bool
    let isStacked: Bool

    func resolve(
        fallback: ProviderInstanceID,
        mergeIcons: Bool,
        enabledProviders: Set<UsageProvider>) -> ProviderInstanceID
    {
        guard mergeIcons,
              !self.isStacked,
              !self.isMergedMenuOpen,
              self.source == .frontmostApp,
              let focusedProvider = self.focusedProvider,
              enabledProviders.contains(focusedProvider)
        else { return fallback }
        return focusedProvider.instanceID
    }

    static func currentSelectionProvider(
        selected: ProviderInstanceID?,
        enabled: Set<ProviderInstanceID>) -> ProviderInstanceID?
    {
        guard let selected, enabled.contains(selected) else { return nil }
        return selected
    }
}
