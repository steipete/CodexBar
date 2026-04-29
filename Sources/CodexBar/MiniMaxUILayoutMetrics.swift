import AppKit

enum MiniMaxUILayoutMetrics {
    static let collapseThreshold = 5
    static let settingsEmbeddedScrollThreshold = 6
    static let settingsEmbeddedScrollMaxHeight: CGFloat = 360
    static let settingsTitleWidthReference = "code-plan-search"
    static let menuScrollFallbackHeight: CGFloat = 560

    static func menuUsageScrollMaxHeight(visibleScreenHeight: CGFloat?) -> CGFloat {
        guard let height = visibleScreenHeight else {
            return self.menuScrollFallbackHeight
        }
        return min(640, max(320, height - 310))
    }

    static func preferredMenuUsageHeight(contentHeight: CGFloat, visibleScreenHeight: CGFloat?) -> CGFloat {
        min(max(1, ceil(contentHeight)), self.menuUsageScrollMaxHeight(visibleScreenHeight: visibleScreenHeight))
    }

    static func settingsTitleWidthCap(font: NSFont = ProviderSettingsMetrics.metricLabelFont()) -> CGFloat {
        ProviderSettingsMetrics.labelWidth(for: [self.settingsTitleWidthReference], font: font)
    }
}
