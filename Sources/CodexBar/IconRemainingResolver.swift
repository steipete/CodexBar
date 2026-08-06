import CodexBarCore
import Foundation

enum IconRemainingResolver {
    private static let visibleZeroPercent = 0.0001

    static func resolvedWindows(
        snapshot: UsageSnapshot,
        style: IconStyle,
        secondaryOverrideWindowID: String? = nil,
        now: Date = Date())
        -> (primary: RateWindow?, secondary: RateWindow?)
    {
        guard let provider = UsageProvider(rawValue: style.rawValue) else {
            return (primary: snapshot.primary, secondary: snapshot.secondary)
        }
        let windows = ProviderDescriptorRegistry.descriptor(for: provider).presentation.iconWindows(
            context: ProviderIconWindowContext(
                snapshot: snapshot,
                secondaryOverrideWindowID: secondaryOverrideWindowID,
                now: now))
        return (primary: windows.primary, secondary: windows.secondary)
    }

    static func resolvedRemaining(
        snapshot: UsageSnapshot,
        style: IconStyle,
        secondaryOverrideWindowID: String? = nil,
        now: Date = Date())
        -> (primary: Double?, secondary: Double?)
    {
        let windows = self.resolvedWindows(
            snapshot: snapshot,
            style: style,
            secondaryOverrideWindowID: secondaryOverrideWindowID,
            now: now)
        return (
            primary: windows.primary?.remainingPercent,
            secondary: windows.secondary?.remainingPercent)
    }

    static func resolvedPercents(
        snapshot: UsageSnapshot,
        style: IconStyle,
        showUsed: Bool,
        renderingStyle: IconStyle? = nil,
        secondaryOverrideWindowID: String? = nil,
        now: Date = Date())
        -> (primary: Double?, secondary: Double?)
    {
        let windows = Self.resolvedWindows(
            snapshot: snapshot,
            style: style,
            secondaryOverrideWindowID: secondaryOverrideWindowID,
            now: now)
        var percents = (
            primary: showUsed ? windows.primary?.usedPercent : windows.primary?.remainingPercent,
            secondary: showUsed ? windows.secondary?.usedPercent : windows.secondary?.remainingPercent)
        // Provider style chooses the usage lanes; rendering style controls renderer-specific layout sentinels.
        // Merged icons still resolve Warp's lanes, but render as `.combined` and must keep the real percentage.
        let presentation = UsageProvider(rawValue: style.rawValue)
            .map { ProviderDescriptorRegistry.descriptor(for: $0).presentation }
        if showUsed,
           presentation?.treatsExhaustedSecondaryIconWindowAsMissing == true,
           (renderingStyle ?? style) == style,
           let secondary = windows.secondary
        {
            if secondary.remainingPercent <= 0 {
                // Preserve Warp's exhausted/no-bonus layout even though used percent is 100.
                percents.secondary = 0
            } else if percents.secondary == 0 {
                // A zero fill means "lane absent" to IconRenderer; keep an unused bonus lane visible.
                percents.secondary = self.visibleZeroPercent
            }
        }
        return percents
    }
}
