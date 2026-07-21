import AppKit
import CodexBarCore
import Foundation

struct MenuBarLayoutRenderWindow: Hashable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?
    let resetDescription: String?

    init?(_ window: RateWindow?) {
        guard let window, !window.isSyntheticPlaceholder else { return nil }
        self.usedPercent = window.usedPercent
        self.windowMinutes = window.windowMinutes
        self.resetsAt = window.resetsAt
        self.resetDescription = window.resetDescription
    }

    var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }
}

struct MenuBarLayoutRenderData: Hashable {
    let iconKey: String
    let providerName: String?
    let accountLabel: String?
    let session: MenuBarLayoutRenderWindow?
    let weekly: MenuBarLayoutRenderWindow?
    let automatic: MenuBarLayoutRenderWindow?
    let runsOut: String?
    let costToday: String?
    let cost30d: String?
}

struct MenuBarLayoutRenderOptions: Hashable {
    let size: MenuBarLayoutSize
    let highContrast: Bool
    let showUsed: Bool
    let appearanceName: String
    let isDebugApp: Bool
    /// Minute-granularity clock. Countdown tokens refresh without invalidating cached titles every tick.
    let now: Date
}

struct MenuBarLayoutRenderKey: Hashable {
    let layout: MenuBarLayout
    let data: MenuBarLayoutRenderData
    let options: MenuBarLayoutRenderOptions
}

struct MenuBarLayoutRenderedTitle {
    let attributedTitle: NSAttributedString
    let accessibilityLabel: String
}

@MainActor
final class MenuBarLayoutTitleCache {
    private let capacity: Int
    private var storage: [MenuBarLayoutRenderKey: MenuBarLayoutRenderedTitle] = [:]

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    func value(
        for key: MenuBarLayoutRenderKey,
        make: () -> MenuBarLayoutRenderedTitle)
        -> MenuBarLayoutRenderedTitle
    {
        if let cached = self.storage[key] {
            return cached
        }
        let value = make()
        if self.storage.count >= self.capacity, let oldest = self.storage.keys.first {
            self.storage.removeValue(forKey: oldest)
        }
        self.storage[key] = value
        return value
    }

    func removeAll() {
        self.storage.removeAll(keepingCapacity: true)
    }

    var count: Int {
        self.storage.count
    }
}

@MainActor
final class MenuBarLayoutRenderer {
    private static let missingValue = "–"

    private struct TokenStyle {
        let font: NSFont
        let foregroundColor: NSColor
        let iconHeight: CGFloat
        let attributes: [NSAttributedString.Key: Any]
    }

    private let cache: MenuBarLayoutTitleCache

    init(cache: MenuBarLayoutTitleCache = MenuBarLayoutTitleCache()) {
        self.cache = cache
    }

    func render(
        layout: MenuBarLayout,
        data: MenuBarLayoutRenderData,
        icon: NSImage?,
        options: MenuBarLayoutRenderOptions)
        -> MenuBarLayoutRenderedTitle
    {
        let key = MenuBarLayoutRenderKey(layout: layout, data: data, options: options)
        return self.cache.value(for: key) {
            Self.renderUncached(layout: layout, data: data, icon: icon, options: options)
        }
    }

    func removeAll() {
        self.cache.removeAll()
    }

    private static func renderUncached(
        layout: MenuBarLayout,
        data: MenuBarLayoutRenderData,
        icon: NSImage?,
        options: MenuBarLayoutRenderOptions)
        -> MenuBarLayoutRenderedTitle
    {
        let isStacked = layout.lines.count == 2
        let font = NSFont.systemFont(ofSize: Self.fontSize(size: options.size, isStacked: isStacked))
        let foregroundColor = options.highContrast ? NSColor.labelColor : NSColor.controlTextColor
        let paragraphStyle = NSMutableParagraphStyle()
        if isStacked {
            paragraphStyle.minimumLineHeight = 9.5
            paragraphStyle.maximumLineHeight = 9.5
            paragraphStyle.lineSpacing = -1
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraphStyle,
        ]
        let result = NSMutableAttributedString()
        var accessibilityLines: [String] = []

        for (lineIndex, line) in layout.lines.enumerated() {
            if lineIndex > 0 {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            var accessibilityParts: [String] = []
            for (tokenIndex, token) in line.enumerated() {
                if tokenIndex > 0, token != .space, line[tokenIndex - 1] != .space {
                    result.append(NSAttributedString(string: "\u{2009}", attributes: attributes))
                }
                let renderedItem = Self.renderItem(
                    token,
                    data: data,
                    icon: icon,
                    style: TokenStyle(
                        font: font,
                        foregroundColor: foregroundColor,
                        iconHeight: Self.iconHeight(size: options.size, isStacked: isStacked),
                        attributes: attributes),
                    options: options)
                result.append(renderedItem.value)
                if let accessibilityText = renderedItem.accessibilityText {
                    accessibilityParts.append(accessibilityText)
                }
            }
            accessibilityLines.append(accessibilityParts.joined(separator: ", "))
        }

        if options.isDebugApp {
            result.append(NSAttributedString(string: " D", attributes: attributes))
            accessibilityLines[accessibilityLines.count - 1].append(", \(L("Debug"))")
        }
        let accessibilityLabel = accessibilityLines.enumerated().map { index, line in
            index == 0 ? line : "\(L("menu_bar_layout_line", index + 1)), \(line)"
        }.joined(separator: ", ")
        return MenuBarLayoutRenderedTitle(
            attributedTitle: result,
            accessibilityLabel: accessibilityLabel)
    }

    private static func renderItem(
        _ item: MenuBarLayoutToken,
        data: MenuBarLayoutRenderData,
        icon: NSImage?,
        style: TokenStyle,
        options: MenuBarLayoutRenderOptions)
        -> (value: NSAttributedString, accessibilityText: String?)
    {
        switch item {
        case .icon:
            guard let icon else {
                return self.textToken(
                    self.missingValue,
                    accessibilityText: L("Icon unavailable"),
                    attributes: style.attributes)
            }
            let attachment = NSTextAttachment()
            attachment.image = Self.attachmentImage(icon, tint: style.foregroundColor)
            let height = style.iconHeight
            let width = icon.size.height > 0 ? icon.size.width * height / icon.size.height : height
            attachment.bounds = NSRect(
                x: 0,
                y: ((style.font.capHeight - height) / 2).rounded(),
                width: width,
                height: height)
            let value = NSMutableAttributedString(attachment: attachment)
            value.addAttributes(style.attributes, range: NSRange(location: 0, length: value.length))
            return (value, L("%@ icon", data.providerName ?? L("Provider")))
        case .providerName:
            return self.optionalTextToken(
                data.providerName,
                unavailableLabel: L("Provider name unavailable"),
                attributes: style.attributes)
        case .accountLabel:
            return self.optionalTextToken(
                data.accountLabel,
                unavailableLabel: L("Account unavailable"),
                attributes: style.attributes)
        case let .percent(window):
            let rateWindow = Self.window(window, data: data)
            let percent = rateWindow.map { options.showUsed ? $0.usedPercent : $0.remainingPercent }
            let value = percent.map(UsageFormatter.percentString) ?? Self.missingValue
            let prefix: String
            let accessibilityPrefix: String
            switch window {
            case .session:
                prefix = Self.sessionPrefix(rateWindow)
                accessibilityPrefix = L("Session")
            case .weekly:
                prefix = "W"
                accessibilityPrefix = L("Weekly")
            case .automatic:
                prefix = ""
                accessibilityPrefix = L("Usage")
            }
            let display = prefix.isEmpty ? value : "\(prefix) \(value)"
            let accessibility = percent == nil
                ? L("%@ unavailable", accessibilityPrefix)
                : L("%@ %@", accessibilityPrefix, value)
            return self.textToken(display, accessibilityText: accessibility, attributes: style.attributes)
        case .usageBar:
            guard let window = data.automatic else {
                return self.textToken(
                    self.missingValue,
                    accessibilityText: L("Usage bar unavailable"),
                    attributes: style.attributes)
            }
            let displayedPercent = options.showUsed ? window.usedPercent : window.remainingPercent
            let filled = Int((displayedPercent.clamped(to: 0...100) / 100 * 3).rounded())
            let value = String(repeating: "▮", count: filled) + String(repeating: "▯", count: 3 - filled)
            return self.textToken(
                value,
                accessibilityText: L("Usage bar, %d of 3 filled", filled),
                attributes: style.attributes)
        case .resetCountdown:
            return self.resetToken(
                data.automatic?.resetsAt.map { UsageFormatter.resetCountdownDescription(from: $0, now: options.now) }
                    ?? data.automatic?.resetDescription,
                unavailableLabel: L("Reset countdown unavailable"),
                attributes: style.attributes)
        case .resetAbsolute:
            return self.resetToken(
                data.automatic?.resetsAt.map { UsageFormatter.resetDescription(from: $0, now: options.now) }
                    ?? data.automatic?.resetDescription,
                unavailableLabel: L("Reset time unavailable"),
                attributes: style.attributes)
        case .runsOut:
            return self.optionalTextToken(
                data.runsOut,
                unavailableLabel: L("Run-out estimate unavailable"),
                attributes: style.attributes)
        case .costToday:
            return self.optionalTextToken(
                data.costToday,
                unavailableLabel: L("Cost today unavailable"),
                attributes: style.attributes)
        case .cost30d:
            return self.optionalTextToken(
                data.cost30d,
                unavailableLabel: L("30-day cost unavailable"),
                attributes: style.attributes)
        case .separatorDot:
            return self.textToken("·", accessibilityText: nil, attributes: style.attributes)
        case .space:
            return self.textToken(" ", accessibilityText: nil, attributes: style.attributes)
        }
    }

    private static func attachmentImage(_ image: NSImage, tint: NSColor) -> NSImage {
        guard image.isTemplate else { return image }

        // NSTextAttachment draws an NSImage directly instead of through an image cell, so AppKit does not
        // apply template tinting here. Keep a template image for status-item semantics while drawing its mask
        // with the same dynamic foreground color as the surrounding title.
        let tintedImage = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        tintedImage.isTemplate = true
        return tintedImage
    }

    private static func resetToken(
        _ value: String?,
        unavailableLabel: String,
        attributes: [NSAttributedString.Key: Any])
        -> (value: NSAttributedString, accessibilityText: String?)
    {
        self.optionalTextToken(
            value,
            unavailableLabel: unavailableLabel,
            accessibilityPrefix: L("Resets"),
            attributes: attributes)
    }

    private static func optionalTextToken(
        _ value: String?,
        unavailableLabel: String,
        accessibilityPrefix: String? = nil,
        attributes: [NSAttributedString.Key: Any])
        -> (value: NSAttributedString, accessibilityText: String?)
    {
        guard let value, !value.isEmpty else {
            return self.textToken(self.missingValue, accessibilityText: unavailableLabel, attributes: attributes)
        }
        let accessibilityText = accessibilityPrefix.map { "\($0) \(value)" } ?? value
        return self.textToken(value, accessibilityText: accessibilityText, attributes: attributes)
    }

    private static func textToken(
        _ value: String,
        accessibilityText: String?,
        attributes: [NSAttributedString.Key: Any])
        -> (value: NSAttributedString, accessibilityText: String?)
    {
        (NSAttributedString(string: value, attributes: attributes), accessibilityText)
    }

    private static func window(
        _ percentWindow: PercentWindow,
        data: MenuBarLayoutRenderData)
        -> MenuBarLayoutRenderWindow?
    {
        switch percentWindow {
        case .session: data.session
        case .weekly: data.weekly
        case .automatic: data.automatic
        }
    }

    private static func sessionPrefix(_ window: MenuBarLayoutRenderWindow?) -> String {
        guard let minutes = window?.windowMinutes, minutes > 0 else { return "S" }
        guard minutes.isMultiple(of: 60) else { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    private static func fontSize(size: MenuBarLayoutSize, isStacked: Bool) -> CGFloat {
        if isStacked {
            return size == .small ? 8 : 9
        }
        return size == .small ? 11 : NSFont.systemFontSize
    }

    private static func iconHeight(size: MenuBarLayoutSize, isStacked: Bool) -> CGFloat {
        if isStacked {
            return size == .small ? 8 : 9
        }
        return size == .small ? 14 : 16
    }
}
