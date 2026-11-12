import AppKit
import CodexBarCore

extension IconRenderer {
    /// Opt-in quota colors for the meter icon (Settings → Menu Bar → Icon → "Color bars by quota left").
    ///
    /// Each bar is green with 50% or more left, orange from 25%, and red below 25%; a lane without a value is gray.
    /// Shades are fixed sRGB values chosen per menu bar appearance so every one passes
    /// `MenuBarLayoutRenderer.meetsAppearanceContrast`, the contrast check provider colors already use.
    struct QuotaColorStyle: Hashable {
        enum Level: Hashable {
            case plenty
            case low
            case critical
            /// No measured value for this lane.
            case unknown
        }

        /// Draw for a dark menu bar (brighter shades) rather than a light one (darker shades).
        let isDarkAppearance: Bool
        /// Bar values are percent used ("Show usage as used") rather than percent left.
        let valuesAreUsed: Bool

        /// Status item render-signature component, so a mode or appearance change redraws the icon.
        var signature: String {
            "\(self.isDarkAppearance ? "dark" : "light")-\(self.valuesAreUsed ? "used" : "left")"
        }

        static func level(forPercentLeft percentLeft: Double?) -> Level {
            guard let percentLeft else { return .unknown }
            if percentLeft >= 50 { return .plenty }
            if percentLeft >= 25 { return .low }
            return .critical
        }

        func level(forBarValue value: Double?) -> Level {
            Self.level(forPercentLeft: value.map { self.valuesAreUsed ? 100 - $0 : $0 })
        }

        static func components(for level: Level, isDarkAppearance: Bool) -> ProviderColor {
            switch (level, isDarkAppearance) {
            case (.plenty, false): self.rgb(36, 138, 61)
            case (.plenty, true): self.rgb(48, 209, 88)
            case (.low, false): self.rgb(194, 97, 0)
            case (.low, true): self.rgb(255, 159, 10)
            case (.critical, false): self.rgb(215, 0, 21)
            case (.critical, true): self.rgb(255, 69, 58)
            case (.unknown, false): self.rgb(110, 110, 115)
            case (.unknown, true): self.rgb(174, 174, 178)
            }
        }

        func color(forBarValue value: Double?) -> NSColor {
            let rgb = Self.components(for: self.level(forBarValue: value), isDarkAppearance: self.isDarkAppearance)
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }

        private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> ProviderColor {
            ProviderColor(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        }
    }

    /// Mirrors `MenuBarLayoutRenderer.effectiveProviderTintColor`: quota colors fall back to the monochrome template
    /// while the item is highlighted, stale or loading, with increased contrast (the inactive-display option or the
    /// system setting), in accessibility appearances, and for appearances without a known light or dark reference.
    static func effectiveQuotaColorStyle(
        options: MenuBarLayoutRenderOptions,
        increasedContrast: Bool,
        isLoading: Bool) -> QuotaColorStyle?
    {
        let appearanceName = options.appearanceName
        guard !options.isHighlighted, !options.isStale, !options.highContrast, !increasedContrast, !isLoading,
              !appearanceName.localizedCaseInsensitiveContains("accessibility")
        else { return nil }
        let isDark = appearanceName.localizedCaseInsensitiveContains("dark")
        guard isDark || appearanceName.localizedCaseInsensitiveContains("aqua")
            || appearanceName.localizedCaseInsensitiveContains("light")
        else { return nil }
        return QuotaColorStyle(isDarkAppearance: isDark, valuesAreUsed: options.showUsed)
    }
}
