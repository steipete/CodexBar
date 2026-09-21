import CodexBarCore

struct MergedIconPresentation: Equatable {
    struct Pair: Equatable {
        let top: UsageProvider
        let bottom: UsageProvider

        var providers: [UsageProvider] {
            [self.top, self.bottom]
        }
    }

    let eligibleProviders: [UsageProvider]
    let topSelection: UsageProvider?
    let bottomSelection: UsageProvider?
    let canStack: Bool
    let stackedProviders: Pair?

    var effectiveStyle: MergedIconDisplayStyle {
        self.stackedProviders == nil ? .switcher : .stacked
    }

    init(
        mergeIcons: Bool,
        iconStyle: MenuBarIconStyle,
        requestedStyle: MergedIconDisplayStyle,
        eligibleProviders: [UsageProvider],
        preferredTop: UsageProvider?,
        preferredBottom: UsageProvider?)
    {
        var seen: Set<UsageProvider> = []
        let providers = eligibleProviders.filter { seen.insert($0).inserted }
        self.eligibleProviders = providers
        let top = preferredTop.flatMap { providers.contains($0) ? $0 : nil }
        let bottom = preferredBottom.flatMap { providers.contains($0) && $0 != top ? $0 : nil }
        self.topSelection = top
        self.bottomSelection = bottom
        self.canStack = mergeIcons && iconStyle == .iconAndPercent && providers.count >= 2

        // Reserve explicit choices before filling Automatic; stale choices never erase persisted intent.
        if self.canStack, requestedStyle == .stacked,
           let resolvedTop = top ?? providers.first(where: { $0 != bottom }),
           let resolvedBottom = bottom ?? providers.first(where: { $0 != resolvedTop })
        {
            self.stackedProviders = Pair(top: resolvedTop, bottom: resolvedBottom)
        } else {
            self.stackedProviders = nil
        }
    }

    func renderedResolution(
        _ resolution: MenuBarLayoutResolution,
        for provider: UsageProvider) -> MenuBarLayoutResolution
    {
        guard self.stackedProviders?.providers.contains(provider) == true else { return resolution }
        // Rendering, observation, and timers must all see the same first line, including migrated layouts.
        return .stored(MenuBarLayout(lines: Array(resolution.layout.lines.prefix(1))))
    }
}
