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
    let provider: UsageProvider
    let iconKey: String
    let providerName: String?
    let accountLabel: String?
    let session: MenuBarLayoutRenderWindow?
    let weekly: MenuBarLayoutRenderWindow?
    let scopedWeekly: MenuBarLayoutRenderWindow?
    /// Title of the active scoped weekly window (e.g. "Fable only"), used to label the
    /// `.scopedWeekly` token with the real model rather than assuming Fable.
    let scopedWeeklyTitle: String?
    let automatic: MenuBarLayoutRenderWindow?
    /// Provider-specific text used by the automatic percent token when no percentage window exists.
    let automaticText: String?
    /// Signed pace deltas per window, already formatted (`+11%`, `-8%`, `0%`). Pace needs the store's
    /// historical dataset and work-day setting, so it is resolved upstream like `runsOut` rather than
    /// derived from the render windows here.
    let sessionPace: String?
    let weeklyPace: String?
    let automaticPace: String?
    let runsOut: String?
    let balance: String?
    let costToday: String?
    let cost30d: String?
}

struct MenuBarLayoutRenderOptions: Hashable {
    let size: MenuBarLayoutSize
    let highContrast: Bool
    let showUsed: Bool
    let appearanceName: String
    let isDebugApp: Bool
    /// Whether the provider's latest refresh failed; when true the shown snapshot is stale
    /// and rendered dimmer until a background refresh succeeds again.
    let isStale: Bool
    /// Exact display clock. The cache keys on the resulting reset strings, so animation ticks that keep
    /// the same visible countdown still reuse the cached title.
    let now: Date
    /// User-tunable vertical nudge for the whole title, applied on top of the optical baseline
    /// offset. Positive moves content up, negative moves it down.
    let verticalAdjustment: Int

    init(
        size: MenuBarLayoutSize,
        highContrast: Bool,
        showUsed: Bool,
        appearanceName: String,
        isDebugApp: Bool,
        isStale: Bool = false,
        now: Date,
        verticalAdjustment: Int = 0)
    {
        self.size = size
        self.highContrast = highContrast
        self.showUsed = showUsed
        self.appearanceName = appearanceName
        self.isDebugApp = isDebugApp
        self.isStale = isStale
        self.now = now
        self.verticalAdjustment = verticalAdjustment
    }
}

struct MenuBarLayoutRenderKey: Hashable {
    let layout: MenuBarLayout
    let data: MenuBarLayoutRenderData
    let size: MenuBarLayoutSize
    let highContrast: Bool
    let showUsed: Bool
    let appearanceName: String
    let isDebugApp: Bool
    let isStale: Bool
    let verticalAdjustment: Int
    let resetText: MenuBarLayoutResetText
}

struct MenuBarLayoutResetText: Hashable {
    let countdown: String?
    let absolute: String?

    init(window: MenuBarLayoutRenderWindow?, now: Date) {
        if let resetsAt = window?.resetsAt {
            self.countdown = UsageFormatter.resetCountdownDescription(from: resetsAt, now: now)
            self.absolute = UsageFormatter.resetDescription(from: resetsAt, now: now)
        } else {
            self.countdown = window?.resetDescription
            self.absolute = window?.resetDescription
        }
    }
}

struct MenuBarLayoutRenderedTitle {
    let attributedTitle: NSAttributedString
    let accessibilityLabel: String
    /// When the layout begins with an icon token, the raw template image is surfaced here so
    /// the status item can assign it to `button.image`. Template images are the only menu bar
    /// content AppKit automatically dims on inactive displays; attributed-title attachments are
    /// pre-rendered bitmaps and do not follow the system's active-state tinting.
    let leadingIcon: NSImage?
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
    private static let stackedBaselineOffset: CGFloat = -3 // Center multi-line NSStatusBarButton titles.
    private static let singleLineBaselineOffset: CGFloat = -1 // Drop single-line titles slightly for optical centering.

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
        let resetText = MenuBarLayoutResetText(window: data.automatic, now: options.now)
        let key = MenuBarLayoutRenderKey(
            layout: layout,
            data: data,
            size: options.size,
            highContrast: options.highContrast,
            showUsed: options.showUsed,
            appearanceName: options.appearanceName,
            isDebugApp: options.isDebugApp,
            isStale: options.isStale,
            verticalAdjustment: options.verticalAdjustment,
            resetText: resetText)
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
        let foregroundColor = if options.highContrast {
            NSColor.labelColor
        } else if options.isStale {
            NSColor.secondaryLabelColor
        } else {
            NSColor.controlTextColor
        }
        let paragraphStyle = NSMutableParagraphStyle()
        if isStacked {
            paragraphStyle.minimumLineHeight = 9.5
            paragraphStyle.maximumLineHeight = 9.5
            paragraphStyle.lineSpacing = -1
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraphStyle,
        ]
        // Optical baseline offset keeps the title vertically balanced in the status bar button.
        // A user-tunable nudge is layered on top so the layout can be fine-tuned per display.
        let baseBaselineOffset = isStacked ? Self.stackedBaselineOffset : Self.singleLineBaselineOffset
        attributes[.baselineOffset] = baseBaselineOffset + CGFloat(options.verticalAdjustment)
        let result = NSMutableAttributedString()
        var accessibilityLines: [String] = []
        // Only surface a leading icon via `button.image` when an actual image is available and the
        // high-contrast contract does not require the icon to stay inside the attributed title.
        // AppKit dims `button.image` on inactive displays, but high-contrast layouts keep icon + text
        // together in one attributed path so the existing dimming contract is preserved. With a
        // missing icon the token still renders its placeholder inside the title.
        let leadingIcon: NSImage? = if options.highContrast {
            nil
        } else if layout.lines.first?.first == .icon, icon != nil {
            icon.map { Self.offsetLeadingIcon($0, adjustment: options.verticalAdjustment) }
        } else {
            nil
        }

        for (lineIndex, line) in layout.lines.enumerated() {
            if lineIndex > 0 {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            var accessibilityParts: [String] = []
            for (tokenIndex, token) in line.enumerated() {
                // The leading icon is surfaced as `button.image` so AppKit applies the system's
                // active/inactive display tinting; it is not repeated inside the attributed title,
                // but its accessibility description must survive for VoiceOver.
                if leadingIcon != nil, lineIndex == 0, tokenIndex == 0, token == .icon {
                    accessibilityParts.append(Self.iconAccessibilityText(data: data))
                    continue
                }
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
            accessibilityLabel: accessibilityLabel,
            leadingIcon: leadingIcon)
    }

    private static func renderItem(
        _ item: MenuBarLayoutToken,
        data: MenuBarLayoutRenderData,
        icon: NSImage?,
        style: TokenStyle,
        options: MenuBarLayoutRenderOptions,
        depth: Int = 0)
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
            return (value, Self.iconAccessibilityText(data: data))
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
            return self.renderPercent(window, data: data, style: style, options: options)
        case let .pace(window):
            let accessibilityPrefix = Self.paceAccessibilityPrefix(window, data: data)
            return self.optionalTextToken(
                Self.pace(window, data: data),
                unavailableLabel: L("%@ unavailable", accessibilityPrefix),
                accessibilityPrefix: accessibilityPrefix,
                attributes: style.attributes)
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
        case .runsOut, .runsOutCompact:
            let isCompact = item == .runsOutCompact
            return self.optionalTextToken(
                isCompact ? data.runsOut.map(self.compactRunsOutText) : data.runsOut,
                unavailableLabel: L("Run-out estimate unavailable"),
                accessibilityText: isCompact ? data.runsOut : nil,
                attributes: style.attributes)
        case .balance:
            return self.optionalTextToken(
                data.balance,
                unavailableLabel: L("%@ unavailable", L("Balance")),
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
        case .hidden:
            return self.textToken("", accessibilityText: nil, attributes: style.attributes)
        case let .conditional(conditional):
            guard depth < MenuBarLayoutToken.maxConditionalDepth else {
                return self.textToken(
                    self.missingValue,
                    accessibilityText: L("Conditional unavailable"),
                    attributes: style.attributes)
            }
            let branch = conditional.evaluatesTrue(data: data) ? conditional.thenToken : conditional.elseToken
            return self.renderItem(branch, data: data, icon: icon, style: style, options: options, depth: depth + 1)
        }
    }

    private static func renderPercent(
        _ window: PercentWindow,
        data: MenuBarLayoutRenderData,
        style: TokenStyle,
        options: MenuBarLayoutRenderOptions)
        -> (value: NSAttributedString, accessibilityText: String?)
    {
        let rateWindow = Self.window(window, data: data)
        let resolvedValue = Self.percentValue(
            window: window,
            rateWindow: rateWindow,
            automaticText: data.automaticText,
            showUsed: options.showUsed)
        let prefix: String
        let accessibilityPrefix: String
        switch window {
        case .session:
            prefix = Self.sessionPrefix(rateWindow)
            accessibilityPrefix = L("Session")
        case .weekly:
            let secondaryLabel = Self.secondaryLabel(data: data)
            prefix = secondaryLabel.flatMap(\.first).map { String($0).uppercased() } ?? "W"
            accessibilityPrefix = secondaryLabel ?? L("Weekly")
        case .scopedWeekly:
            prefix = data.scopedWeeklyTitle.map { String($0.prefix(1)).uppercased() } ?? "F"
            accessibilityPrefix = data.scopedWeeklyTitle ?? L("Scoped weekly")
        case .automatic:
            prefix = ""
            accessibilityPrefix = L("Usage")
        }
        let display = prefix.isEmpty ? resolvedValue.text : "\(prefix) \(resolvedValue.text)"
        let accessibility = resolvedValue.isAvailable
            ? L("%@ %@", accessibilityPrefix, resolvedValue.text)
            : L("%@ unavailable", accessibilityPrefix)
        return self.textToken(display, accessibilityText: accessibility, attributes: style.attributes)
    }

    private static func iconAccessibilityText(data: MenuBarLayoutRenderData) -> String {
        L("%@ icon", data.providerName ?? L("Provider"))
    }

    private static func percentValue(
        window: PercentWindow,
        rateWindow: MenuBarLayoutRenderWindow?,
        automaticText: String?,
        showUsed: Bool)
        -> (text: String, isAvailable: Bool)
    {
        if let rateWindow {
            let percent = showUsed ? rateWindow.usedPercent : rateWindow.remainingPercent
            return (UsageFormatter.percentString(percent), true)
        }
        if window == .automatic, let automaticText {
            return (automaticText, true)
        }
        return (Self.missingValue, false)
    }

    private static func compactRunsOutText(_ text: String) -> String {
        let nowLabel = L("Runs out now")
        if text.hasPrefix(nowLabel) {
            return "now" + text.dropFirst(nowLabel.count)
        }

        let marker = "\u{F8FF}"
        let localizedTemplate = L("Runs out in %@", marker)
        guard let markerRange = localizedTemplate.range(of: marker) else { return text }

        let prefix = localizedTemplate[..<markerRange.lowerBound]
        let suffix = localizedTemplate[markerRange.upperBound...]
        guard text.hasPrefix(prefix) else { return text }

        let withoutPrefix = text.dropFirst(prefix.count)
        guard !suffix.isEmpty,
              let suffixRange = withoutPrefix.range(of: suffix)
        else { return String(withoutPrefix) }
        return String(withoutPrefix[..<suffixRange.lowerBound]) + String(withoutPrefix[suffixRange.upperBound...])
    }

    private static func offsetLeadingIcon(_ image: NSImage, adjustment: Int) -> NSImage {
        // Bake the offset into the surfaced image so the status button and preferences preview share it.
        // Cap the canvas at the 22 pt menu bar content height to avoid proportional downscaling.
        let maxShift = max(0, floor((22 - image.size.height) / 2))
        let shift = min(CGFloat(abs(adjustment)), maxShift)
        guard adjustment != 0, shift > 0 else { return image }

        let offsetImage = NSImage(
            size: NSSize(width: image.size.width, height: image.size.height + 2 * shift),
            flipped: false)
        { _ in
            image.draw(
                in: NSRect(
                    x: 0,
                    y: adjustment > 0 ? 2 * shift : 0,
                    width: image.size.width,
                    height: image.size.height))
            return true
        }
        offsetImage.isTemplate = true
        return offsetImage
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
        accessibilityText: String? = nil,
        attributes: [NSAttributedString.Key: Any])
        -> (value: NSAttributedString, accessibilityText: String?)
    {
        guard let value, !value.isEmpty else {
            return self.textToken(self.missingValue, accessibilityText: unavailableLabel, attributes: attributes)
        }
        let resolvedAccessibilityText = accessibilityText ?? accessibilityPrefix.map { "\($0) \(value)" } ?? value
        return self.textToken(value, accessibilityText: resolvedAccessibilityText, attributes: attributes)
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
        case .scopedWeekly: data.scopedWeekly
        case .automatic: data.automatic
        }
    }

    private static func pace(
        _ percentWindow: PercentWindow,
        data: MenuBarLayoutRenderData)
        -> String?
    {
        switch percentWindow {
        case .session: data.sessionPace
        case .weekly: data.weeklyPace
        case .scopedWeekly: nil
        case .automatic: data.automaticPace
        }
    }

    private static func paceAccessibilityPrefix(
        _ percentWindow: PercentWindow,
        data: MenuBarLayoutRenderData)
        -> String
    {
        switch percentWindow {
        case .session: L("menu_bar_layout_token_session_pace")
        case .weekly:
            if let secondaryLabel = secondaryLabel(data: data) {
                L("%@ %@", secondaryLabel, L("display_mode_pace").lowercased())
            } else {
                L("menu_bar_layout_token_weekly_pace")
            }
        case .scopedWeekly: L("menu_bar_layout_token_weekly_pace")
        case .automatic: L("menu_bar_layout_token_auto_pace")
        }
    }

    private static func secondaryLabel(data: MenuBarLayoutRenderData) -> String? {
        ProviderDescriptorRegistry.descriptor(for: data.provider).presentation.menuBarLayoutSecondaryLabel.map(L)
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
        return size == .small ? 14 : 18
    }
}

extension MenuBarLayoutConditional {
    /// Left-fold over clauses; a predicate on a missing window (nil) evaluates false.
    func evaluatesTrue(data: MenuBarLayoutRenderData) -> Bool {
        guard let first = self.clauses.first else { return false }
        var result = Self.test(first.predicate, data: data)
        for clause in self.clauses.dropFirst() {
            let value = Self.test(clause.predicate, data: data)
            switch clause.combinator {
            case .or: result = result || value
            case .and, .none: result = result && value
            }
        }
        return result
    }

    private static func test(_ predicate: MenuBarConditionalPredicate, data: MenuBarLayoutRenderData) -> Bool {
        guard let value = Self.value(for: predicate.metric, in: data) else { return false }
        return predicate.comparison.evaluate(value, predicate.threshold)
    }

    private static func value(for metric: MenuBarConditionalMetric, in data: MenuBarLayoutRenderData) -> Double? {
        switch metric {
        case .session: data.session?.usedPercent
        case .weekly: data.weekly?.usedPercent
        case .scopedWeekly: data.scopedWeekly?.usedPercent
        case .automatic: data.automatic?.usedPercent
        }
    }
}
