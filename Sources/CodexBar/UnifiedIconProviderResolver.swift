import CodexBarCore

struct UnifiedIconContext: Equatable, Sendable {
    let source: UnifiedIconSource
    let focusedProvider: UsageProvider?
    let isMergedMenuOpen: Bool
    let isStacked: Bool

    func resolve(
        fallback: UsageProvider,
        mergeIcons: Bool,
        enabledProviders: Set<UsageProvider>) -> UsageProvider
    {
        guard mergeIcons,
              !self.isStacked,
              !self.isMergedMenuOpen,
              self.source == .frontmostApp,
              let focusedProvider = self.focusedProvider,
              enabledProviders.contains(focusedProvider)
        else { return fallback }
        return focusedProvider
    }
}
