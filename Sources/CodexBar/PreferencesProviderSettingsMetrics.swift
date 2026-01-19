import AppKit
import SwiftUI

enum ProviderSettingsMetrics {
    static let rowSpacing: CGFloat = 12
    static let rowInsets = EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
    static let dividerBottomInset: CGFloat = 8
    static let listTopPadding: CGFloat = 12
    static let checkboxSize: CGFloat = 18
    static let iconSize: CGFloat = 18
    static let reorderHandleSize: CGFloat = 12
    static let reorderDotSize: CGFloat = 2
    static let reorderDotSpacing: CGFloat = 3
    static let pickerLabelWidth: CGFloat = 92
    static let sidebarWidth: CGFloat = 240
    static let sidebarCornerRadius: CGFloat = 12
    static let sidebarSubtitleHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let layout = NSLayoutManager()
        return ceil(layout.defaultLineHeight(for: font) * 2)
    }()

    static let detailMaxWidth: CGFloat = 640
    static let metricLabelWidth: CGFloat = 120
    static let metricBarWidth: CGFloat = 220

    static func labelWidth(for labels: [String], font: NSFont, minimum: CGFloat = 0) -> CGFloat {
        let maxWidth = labels
            .filter { !$0.isEmpty }
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return max(minimum, ceil(maxWidth))
    }

    static func metricLabelFont() -> NSFont {
        let baseSize = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        return NSFont.systemFont(ofSize: baseSize, weight: .semibold)
    }

    static func infoLabelFont() -> NSFont {
        NSFont.preferredFont(forTextStyle: .footnote)
    }
}
