import AppKit
import CodexBarCore
import CoreText
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

/// Numeric values behind the display strings on `MenuBarLayoutRenderData`. The strings are formatted
/// for the menu bar and cannot be compared, so conditional predicates read these instead.
///
/// Pace deltas and `runsOutMinutes` are deliberately pre-rounded to the same granularity as the text
/// they mirror (`MenuBarDisplayText.paceText` rounds to whole percentage points): an unrounded value
/// drifts on every clock tick and would defeat `MenuBarLayoutTitleCache`, which keys on this struct.
struct MenuBarLayoutRenderMetrics: Hashable {
    /// Usage-ahead delta in whole percentage points, independent of the display sign preference.
    let sessionPaceDelta: Double?
    let weeklyPaceDelta: Double?
    let automaticPaceDelta: Double?
    /// Whole minutes until the projected run-out (`UsagePace.etaSeconds`).
    let runsOutMinutes: Int?
    /// USD amounts mirroring `balance` / `costToday` / `cost30d`. Provider amounts reported in another
    /// currency are converted to USD so thresholds do not move when the user's display currency does.
    let balanceRemainingUSD: Double?
    let balanceUsedUSD: Double?
    let costTodayUSD: Double?
    let cost30dUSD: Double?
    var spendPaceDelta: Double?
    /// USD-only like the cost amounts: nil for credit-denominated caps and currencies with no exchange rate.
    var spendUsedUSD: Double?
    var spendRemainingUSD: Double?

    static let unavailable = MenuBarLayoutRenderMetrics(
        sessionPaceDelta: nil,
        weeklyPaceDelta: nil,
        automaticPaceDelta: nil,
        runsOutMinutes: nil,
        balanceRemainingUSD: nil,
        balanceUsedUSD: nil,
        costTodayUSD: nil,
        cost30dUSD: nil)
}

struct MenuBarLayoutRenderData: Hashable {
    let provider: UsageProvider
    var quotaIsEstimated = false
    let iconKey: String
    let providerName: String?
    let accountLabel: String?
    let laneLabels: MenuBarLayoutLaneLabels
    let primary: MenuBarLayoutRenderWindow?
    let secondary: MenuBarLayoutRenderWindow?
    let tertiary: MenuBarLayoutRenderWindow?
    var extraRateWindows: [MenuBarLayoutRenderExtra] = []
    let session: MenuBarLayoutRenderWindow?
    let weekly: MenuBarLayoutRenderWindow?
    let scopedWeekly: MenuBarLayoutRenderWindow?
    /// Title of the active scoped weekly window (e.g. "Fable only"), used to label the
    /// `.scopedWeekly` token with the real model rather than assuming Fable.
    let scopedWeeklyTitle: String?
    let automatic: MenuBarLayoutRenderWindow?
    /// Provider-specific text that replaces the automatic percent token: Mistral spend when its
    /// automatic lane has no percentage window, balance-only providers (DeepSeek, DeepInfra) whose
    /// window percent is meaningless, or no-window providers (Moonshot, Poe, OpenCode Go,
    /// OpenRouter) surfacing their balance instead of a missing-value placeholder.
    let automaticText: String?
    /// Signed pace deltas per window, already formatted (`+11%`, `-8%`, `0%`). Pace needs the store's
    /// historical dataset and work-day setting, so it is resolved upstream like `runsOut` rather than
    /// derived from the render windows here.
    let sessionPace: String?
    let weeklyPace: String?
    let automaticPace: String?
    let runsOut: String?
    let balance: String?
    var tokensPerMinute: Int?
    var tokensSparkline: MenuBarTokensSparkline?
    let costToday: String?
    let cost30d: String?
    /// Numeric twins of the display strings above, for conditional predicates.
    let metrics: MenuBarLayoutRenderMetrics
    /// Money is nil for credit-denominated caps, whose percent renders without a currency prefix.
    var spend: MenuBarLayoutRenderWindow?
    var spendPace: String?
    var spendAmount: String?
    var spendBudget: String?
    var spendCurrencySymbol = "$"

    func extraTitle(_ id: String) -> String? {
        ProviderDescriptorRegistry.descriptor(for: self.provider).menuBarMetrics.namedExtras[id].map { title in
            L(self.extraRateWindows.first { $0.id == id }?.title ?? title)
        }
    }

    func extraWindow(_ id: String) -> MenuBarLayoutRenderExtra? {
        guard self.extraTitle(id) != nil else { return nil }
        return self.extraRateWindows.first { $0.id == id && $0.window != nil }
    }
}

struct MenuBarLayoutRenderExtra: Hashable {
    let id: String
    let title: String
    let window: MenuBarLayoutRenderWindow?

    init(_ namedWindow: NamedRateWindow) {
        self.id = namedWindow.id
        self.title = namedWindow.title
        self.window = namedWindow.usageKnown ? MenuBarLayoutRenderWindow(namedWindow.window) : nil
    }

    static func signature(tokens: [MenuBarLayoutToken], provider: UsageProvider, snapshot: UsageSnapshot?) -> Int? {
        let ids = Set(tokens.compactMap { token -> String? in
            if case let .extraPercent(id) = token { return id }
            return nil
        })
        guard !ids.isEmpty else { return nil }
        return MenuBarLayoutNamedExtra.windows(provider: provider, snapshot: snapshot)
            .filter { ids.contains($0.id) }.map(Self.init).hashValue
    }
}

struct MenuBarLayoutRenderOptions: Hashable {
    let size: MenuBarLayoutSize
    let monospacedDigits: Bool
    let showWindowLabels: Bool
    let colorPace: Bool
    let colorByProvider: Bool
    let highContrast: Bool
    let showUsed: Bool
    let conditionals: [MenuBarLayoutConditional]
    let appearanceName: String
    let isDebugApp: Bool
    /// Whether the provider's latest refresh failed; when true the shown snapshot is stale
    /// and rendered dimmer until a background refresh succeeds again.
    let isStale: Bool
    /// Whether the status item is currently highlighted (e.g. tracking an open menu).
    let isHighlighted: Bool
    /// Exact display clock. The cache keys on the resulting reset strings, so animation ticks that keep
    /// the same visible countdown still reuse the cached title.
    let now: Date
    /// User-tunable vertical nudge for the whole title, applied on top of the optical baseline
    /// offset. Positive moves content up, negative moves it down.
    let verticalAdjustment: Int
    /// Forces stacked typography (tight line height, inline icon) even when this render call only
    /// produces a single line. Used to render one row of a multi-provider stacked status item, where
    /// each provider is rendered independently and the results are joined afterward.
    let forceStackedStyle: Bool

    init(
        size: MenuBarLayoutSize,
        highContrast: Bool,
        showUsed: Bool,
        conditionals: [MenuBarLayoutConditional],
        appearanceName: String,
        isDebugApp: Bool,
        isStale: Bool = false,
        isHighlighted: Bool = false,
        now: Date,
        verticalAdjustment: Int = 0,
        colorPace: Bool = false,
        colorByProvider: Bool = false,
        forceStackedStyle: Bool = false,
        monospacedDigits: Bool = false,
        showWindowLabels: Bool = true)
    {
        self.size = size
        self.monospacedDigits = monospacedDigits
        self.showWindowLabels = showWindowLabels
        self.colorPace = colorPace
        self.colorByProvider = colorByProvider
        self.highContrast = highContrast
        self.showUsed = showUsed
        self.conditionals = conditionals
        self.appearanceName = appearanceName
        self.isDebugApp = isDebugApp
        self.isStale = isStale
        self.isHighlighted = isHighlighted
        self.now = now
        self.verticalAdjustment = verticalAdjustment
        self.forceStackedStyle = forceStackedStyle
    }
}

struct MenuBarLayoutRenderKey: Hashable {
    let layout: MenuBarLayout
    let data: MenuBarLayoutRenderData
    let size: MenuBarLayoutSize
    let monospacedDigits: Bool
    let showWindowLabels: Bool
    let colorPace: Bool
    let highContrast: Bool
    let showUsed: Bool
    let conditionals: [MenuBarLayoutConditional]
    let appearanceName: String
    let isDebugApp: Bool
    let isStale: Bool
    let isHighlighted: Bool
    let verticalAdjustment: Int
    let forceStackedStyle: Bool
    let providerAccentColor: String?
    let resetText: [MenuBarLayoutResetText]
    /// Truth value per conditional id. Predicates can read the clock (time to reset), so two renders
    /// with identical data and reset text can still need different branches; keying on the outcomes
    /// keeps the cache correct without putting `now` — which ticks constantly — into the key.
    let conditionalOutcomes: [UUID: Bool]
}

struct MenuBarLayoutResetText: Hashable {
    let value: String?

    init(window: MenuBarLayoutRenderWindow?, provider: UsageProvider, now: Date, absolute: Bool) {
        let metadata = ProviderDescriptorRegistry.descriptor(for: provider).metadata
        // Balance-only providers keep their documented legacy reset-token balance aliases.
        let fallback = metadata.usesDetailBackedWindow && !metadata.balanceOnly ? nil : window?.resetDescription
        self.value = window?.resetsAt.map { date in
            absolute
                ? UsageFormatter.resetDescription(from: date, now: now)
                : UsageFormatter.resetCountdownDescription(from: date, now: now)
        } ?? fallback
    }
}

struct MenuBarLayoutRenderedTitle {
    let attributedTitle: NSAttributedString
    let accessibilityLabel: String
    let statusImage: NSImage?
    /// When the layout begins with an icon token, the raw template image is surfaced here so
    /// the status item can assign it to `button.image`. Template images are the only menu bar
    /// content AppKit automatically dims on inactive displays; attributed-title attachments are
    /// pre-rendered bitmaps and do not follow the system's active-state tinting.
    let leadingIcon: NSImage?

    init(
        attributedTitle: NSAttributedString,
        accessibilityLabel: String,
        leadingIcon: NSImage?,
        statusImage: NSImage? = nil)
    {
        self.attributedTitle = attributedTitle
        self.accessibilityLabel = accessibilityLabel
        self.leadingIcon = leadingIcon
        self.statusImage = statusImage
    }

    func statusItemWidth(gap: MenuBarLayoutGap) -> CGFloat {
        let bounds = self.attributedTitle.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(18, ceil(bounds.width + (self.leadingIcon?.size.width ?? 0)) + (gap == .tight ? 3 : 10))
    }
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
// swiftlint:disable:next type_body_length
final class MenuBarLayoutRenderer {
    private static let missingValue = "–"
    private static let stackedBaselineOffset: CGFloat = -3 // Center multi-line NSStatusBarButton titles.
    private static let windowPrefixKey = NSAttributedString.Key("CodexBarWindowPrefix")
    private static let singleLineBaselineOffset: CGFloat = -1 // Drop single-line titles slightly for optical centering.

    private struct TokenStyle {
        let font: NSFont
        let foregroundColor: NSColor
        let iconHeight: CGFloat
        let attributes: [NSAttributedString.Key: Any]
    }

    private let cache: MenuBarLayoutTitleCache
    let pluginSummary = PluginMenuBarSummaryRenderer()

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
        var seenResetWindows: [Bool: Set<PercentWindow>] = [:]
        let resetText = layout.flattenedTokens(conditionals: options.conditionals).compactMap { token in
            token.resetWindow.flatMap { window in
                seenResetWindows[token.resetIsAbsolute, default: []].insert(window).inserted
                    ? MenuBarLayoutResetText(
                        window: Self.window(window, data: data),
                        provider: data.provider,
                        now: options.now,
                        absolute: token.resetIsAbsolute) : nil
            }
        }
        // Evaluate each conditional exactly once per render: the outcome is both a cache-key component
        // and what the token resolver needs, so re-testing per placement would only duplicate work.
        let outcomes = Dictionary(
            options.conditionals.map { ($0.id, $0.evaluatesTrue(data: data, now: options.now)) },
            uniquingKeysWith: { first, _ in first })
        let accentColor = options.colorByProvider ? ProviderAccentPalette.color(for: data.provider).hexString : nil
        let key = MenuBarLayoutRenderKey(
            layout: layout,
            data: data,
            size: options.size,
            monospacedDigits: options.monospacedDigits,
            showWindowLabels: options.showWindowLabels,
            colorPace: options.colorPace,
            highContrast: options.highContrast,
            showUsed: options.showUsed,
            conditionals: options.conditionals,
            appearanceName: options.appearanceName,
            isDebugApp: options.isDebugApp,
            isStale: options.isStale,
            isHighlighted: options.isHighlighted,
            verticalAdjustment: options.verticalAdjustment,
            forceStackedStyle: options.forceStackedStyle,
            providerAccentColor: accentColor,
            resetText: resetText,
            conditionalOutcomes: outcomes)
        return self.cache.value(for: key) {
            Self.renderUncached(
                layout: layout,
                data: data,
                icon: icon,
                options: options,
                outcomes: outcomes)
        }
    }

    func removeAll() {
        self.cache.removeAll()
        self.pluginSummary.removeAll()
    }

    /// Joins two rows independently rendered for different providers (each with
    /// `forceStackedStyle: true`) into a single stacked status item title. Used by the "Stacked"
    /// combined-icon style, which shows exactly two providers' own single-line content on top of
    /// each other instead of switching between them.
    static func composeStackedProviderRows(
        top: MenuBarLayoutRenderedTitle,
        bottom: MenuBarLayoutRenderedTitle,
        topProviderName: String,
        bottomProviderName: String)
        -> MenuBarLayoutRenderedTitle
    {
        // A row's own accessibility label only names its provider when the row's configured tokens
        // happen to include the icon or provider-name token; a preset like Compact Stacked can omit
        // both, leaving VoiceOver unable to tell which value belongs to which provider. Naming the
        // provider here, independent of the visible tokens, keeps that identification correct for
        // every layout, not just the ones that happen to render it.
        if top.attributedTitle.length == 0 || bottom.attributedTitle.length == 0 {
            let (providerName, row) = top.attributedTitle.length == 0
                ? (bottomProviderName, bottom) : (topProviderName, top)
            return MenuBarLayoutRenderedTitle(
                attributedTitle: row.attributedTitle,
                accessibilityLabel: "\(providerName), \(row.accessibilityLabel)",
                leadingIcon: row.leadingIcon,
                statusImage: row.statusImage)
        }

        let result = NSMutableAttributedString(attributedString: top.attributedTitle)
        let breakAttributes = top.attributedTitle.attributes(at: top.attributedTitle.length - 1, effectiveRange: nil)
        result.append(NSAttributedString(string: "\n", attributes: breakAttributes))
        result.append(bottom.attributedTitle)
        self.alignWindowPrefixes(in: result)
        let secondLineLabel = L("menu_bar_layout_line", 2)
        let accessibilityLabel = "\(topProviderName), \(top.accessibilityLabel), " +
            "\(secondLineLabel), \(bottomProviderName), \(bottom.accessibilityLabel)"
        return MenuBarLayoutRenderedTitle(
            attributedTitle: result,
            accessibilityLabel: accessibilityLabel,
            leadingIcon: nil,
            statusImage: Self.statusImage(title: result, foregroundColor: .controlTextColor))
    }

    private static func renderUncached(
        layout: MenuBarLayout,
        data: MenuBarLayoutRenderData,
        icon: NSImage?,
        options: MenuBarLayoutRenderOptions,
        outcomes: [UUID: Bool])
        -> MenuBarLayoutRenderedTitle
    {
        let conditionalsByID = Dictionary(
            options.conditionals.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })

        // Pre-resolve conditionals so .hidden branches vanish and adjacent-space checks see
        // only the tokens that will actually render. A line left with nothing to render is dropped
        // entirely: keeping it would emit a stray newline, hold the title in stacked typography,
        // and announce a blank line to VoiceOver.
        var renderedLines = layout.lines
            .map { line in
                line.compactMap {
                    Self.resolvedDisplayToken(
                        $0,
                        data: data,
                        conditionals: conditionalsByID,
                        outcomes: outcomes)
                }
            }
            .filter { !$0.isEmpty }

        Self.removeDuplicateBalanceResets(from: &renderedLines, data: data)

        let isStacked = options.forceStackedStyle || renderedLines.count == 2
        let fontSize = Self.fontSize(size: options.size, isStacked: isStacked)
        let font = options.monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: isStacked ? .medium : .regular)
            : NSFont.systemFont(ofSize: fontSize, weight: isStacked ? .medium : .regular)
        let providerTintColor = Self.effectiveProviderTintColor(for: data.provider, options: options)
        let foregroundColor = providerTintColor ?? Self.neutralForegroundColor(options)
        let isTintActive = providerTintColor != nil
        let paragraphStyle = NSMutableParagraphStyle()
        if isStacked {
            let lineHeight: CGFloat = options.size == .large ? 11 : 9.5
            paragraphStyle.minimumLineHeight = lineHeight
            paragraphStyle.maximumLineHeight = lineHeight
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

        // A single leading icon can span both text rows. Separate provider rows and layouts with
        // multiple icons or an icon-only first row keep their icons inline to preserve row ownership.
        let canSurfaceStackedIcon = !options.forceStackedStyle && renderedLines.count == 2
            && renderedLines.joined().filter { $0 == .icon }.count == 1
            && renderedLines[0].contains { $0 != .icon && $0 != .space }
        // High-contrast layouts keep icon + text together for consistent rendering.
        // Provider-colored layouts keep the icon in attributed title to preserve the custom tint.
        // With a missing icon the token still renders its placeholder inside the title.
        let leadingIcon: NSImage? = if options.highContrast || (isStacked && !canSurfaceStackedIcon) || isTintActive {
            nil
        } else if renderedLines.first?.first == .icon, icon != nil {
            icon.map { Self.offsetLeadingIcon($0, adjustment: options.verticalAdjustment) }
        } else {
            nil
        }

        if isStacked, options.size == .large, leadingIcon == nil, icon != nil,
           renderedLines.joined().contains(.icon)
        {
            // Inline attachments need less baseline lowering to fit both rows in the 22pt status bar.
            attributes[.baselineOffset] = Self.stackedBaselineOffset + 2 + CGFloat(options.verticalAdjustment)
        }

        let automaticLabel = Self.automaticWindowLabel(data: data)
        for (lineIndex, renderedLine) in renderedLines.enumerated() {
            if lineIndex > 0 {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            var accessibilityParts: [String] = []
            var lineWindowLabel: String?
            for (tokenIndex, token) in renderedLine.enumerated() {
                // The leading icon is surfaced as `button.image` so AppKit applies the system's
                // active/inactive display tinting; it is not repeated inside the attributed title,
                // but its accessibility description must survive for VoiceOver.
                if leadingIcon != nil, lineIndex == 0, tokenIndex == 0, token == .icon {
                    accessibilityParts.append(Self.iconAccessibilityText(data: data))
                    continue
                }
                if tokenIndex > 0, token != .space, renderedLine[tokenIndex - 1] != .space {
                    result.append(NSAttributedString(string: "\u{2009}", attributes: attributes))
                }
                var renderedItem = Self.renderItem(
                    token,
                    data: data,
                    icon: icon,
                    style: TokenStyle(
                        font: font,
                        foregroundColor: foregroundColor,
                        iconHeight: Self.iconHeight(size: options.size, isStacked: isStacked),
                        attributes: attributes),
                    options: options,
                    providerTintColor: providerTintColor)
                switch token {
                case .percent(window: .automatic), .pace(window: .automatic), .resetCountdown, .resetAbsolute,
                     .windowResetCountdown(window: .automatic), .windowResetAbsolute(window: .automatic):
                    if let label = automaticLabel {
                        renderedItem.value = Self.prefixedValue(
                            options.showWindowLabels && label.short != lineWindowLabel ? label.short : "",
                            value: renderedItem.value,
                            attributes: attributes)
                        // VoiceOver names every window, even when the visible prefix is shared.
                        renderedItem.accessibilityText = renderedItem.accessibilityText
                            .map { L("%@: %@", label.full, $0) }
                        lineWindowLabel = label.short
                    }
                case .space, .separatorDot: break
                default:
                    lineWindowLabel = renderedItem.value.length > 0
                        ? renderedItem.value
                        .attribute(Self.windowPrefixKey, at: 0, effectiveRange: nil) as? String : nil
                }
                result.append(renderedItem.value)
                if let accessibilityText = renderedItem.accessibilityText {
                    accessibilityParts.append(accessibilityText)
                }
            }
            accessibilityLines.append(accessibilityParts.joined(separator: ", "))
        }

        if isStacked {
            Self.alignWindowPrefixes(in: result, promotedIcon: leadingIcon != nil)
        }
        if options.isDebugApp {
            result.append(NSAttributedString(string: " D", attributes: attributes))
            // Every line can collapse when a conditional hides the only token in the layout.
            if accessibilityLines.isEmpty {
                accessibilityLines.append(L("Debug"))
            } else {
                accessibilityLines[accessibilityLines.count - 1].append(", \(L("Debug"))")
            }
        }
        let accessibilityLabel = accessibilityLines.enumerated().map { index, line in
            index == 0 ? line : "\(L("menu_bar_layout_line", index + 1)), \(line)"
        }.joined(separator: ", ")
        return MenuBarLayoutRenderedTitle(
            attributedTitle: result,
            accessibilityLabel: accessibilityLabel,
            leadingIcon: leadingIcon,
            statusImage: !options.highContrast && !options.isStale && !isTintActive && leadingIcon == nil
                && result.string.filter(\.isNewline).count == max(0, renderedLines.count - 1)
                ? Self.statusImage(title: result, foregroundColor: foregroundColor)
                : nil)
    }

    private static func removeDuplicateBalanceResets(
        from lines: inout [[MenuBarLayoutToken]],
        data: MenuBarLayoutRenderData)
    {
        // A balance fallback is not a second reset value when automatic percent already shows it.
        guard let balance = data.automaticText, data.automatic?.resetsAt == nil,
              data.automatic?.resetDescription == balance,
              lines.joined().contains(.percent(window: .automatic))
              || lines.joined().contains(.progressBar(window: .automatic))
        else { return }
        func isSpacing(_ token: MenuBarLayoutToken) -> Bool {
            token.isVisibleSeparator || token == .space
        }
        lines = lines.map { line in
            guard line.contains(.resetCountdown) || line.contains(.resetAbsolute) else { return line }
            var tokens = line
            while let index = tokens.firstIndex(where: { $0 == .resetCountdown || $0 == .resetAbsolute }) {
                tokens.remove(at: index)
                if tokens.prefix(index).allSatisfy(isSpacing) {
                    while let first = tokens.first, isSpacing(first) {
                        tokens.removeFirst()
                    }
                } else if tokens.dropFirst(index).allSatisfy(isSpacing) {
                    while let last = tokens.last, isSpacing(last) {
                        tokens.removeLast()
                    }
                } else {
                    var left = index
                    var right = index
                    while left > 0, isSpacing(tokens[left - 1]) {
                        left -= 1
                    }
                    while right < tokens.count, isSpacing(tokens[right]) {
                        right += 1
                    }
                    if left < index, right > index {
                        let keepRight = tokens[index..<right].contains(where: \.isVisibleSeparator)
                            || !tokens[left..<index].contains(where: \.isVisibleSeparator)
                        tokens.removeSubrange(keepRight ? left..<index : index..<right)
                    }
                }
            }
            return tokens
        }.filter { !$0.isEmpty }
    }

    static func pluginSummaryTitle(
        _ title: NSAttributedString, accessibilityLabel: String, highContrast: Bool) -> MenuBarLayoutRenderedTitle
    {
        MenuBarLayoutRenderedTitle(
            attributedTitle: title,
            accessibilityLabel: accessibilityLabel,
            leadingIcon: nil,
            statusImage: highContrast ? nil : self.statusImage(title: title, foregroundColor: .labelColor))
    }

    private static func statusImage(title: NSAttributedString, foregroundColor: NSColor) -> NSImage? {
        guard title.length > 0 else { return nil }
        // Preserve colored glyphs and attachments; monochrome attachment masks may join the template.
        let line = CTLineCreateWithAttributedString(title)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
        for run in runs {
            let runAttributes = CTRunGetAttributes(run) as NSDictionary
            let attributes = title.attributes(at: CTRunGetStringRange(run).location, effectiveRange: nil)
            guard attributes[.foregroundColor] as? NSColor == foregroundColor,
                  (attributes[.attachment] as? NSTextAttachment)?.image?.isTemplate != false,
                  let font = runAttributes[kCTFontAttributeName] as? NSFont,
                  !CTFontGetSymbolicTraits(font as CTFont).contains(.traitColorGlyphs)
            else { return nil }
        }
        let baseline = (title.attribute(.baselineOffset, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
        let unshiftedTitle = NSMutableAttributedString(attributedString: title)
        unshiftedTitle.removeAttribute(.baselineOffset, range: NSRange(location: 0, length: title.length))
        let immutableTitle = NSAttributedString(attributedString: unshiftedTitle)
        let bounds = unshiftedTitle.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = NSSize(width: max(1, ceil(bounds.width)), height: 22)
        // NSStatusBarButton's native title baseline sits one point above the image canvas's geometric center.
        let titleRect = NSRect(
            x: -bounds.minX,
            y: floor((size.height - bounds.height) / 2) - bounds.minY + baseline + 1,
            width: bounds.width,
            height: bounds.height)
        // Drawing handlers preserve the destination scale; the template lets AppKit own highlight and inactive tinting.
        // Capture immutable content only: AppKit can call the handler away from the main thread.
        let image = NSImage(size: size, flipped: false) { _ in
            immutableTitle.draw(with: titleRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            return true
        }
        image.isTemplate = true
        return image
    }

    /// nil == resolved to .hidden (render nothing, no separator). A returned .conditional
    /// means the id is dangling or the depth cap was hit; renderItem shows the placeholder.
    private static func resolvedDisplayToken(
        _ token: MenuBarLayoutToken,
        data: MenuBarLayoutRenderData,
        conditionals: [UUID: MenuBarLayoutConditional],
        outcomes: [UUID: Bool],
        depth: Int = 0)
        -> MenuBarLayoutToken?
    {
        switch token {
        case .hidden: return nil
        case let .extraPercent(id): return data.extraTitle(id) == nil ? nil : token
        case let .conditional(id):
            guard depth < MenuBarLayoutToken.maxConditionalDepth,
                  let conditional = conditionals[id],
                  let isTrue = outcomes[id]
            else { return token }
            let branch = isTrue ? conditional.thenToken : conditional.elseToken
            return self.resolvedDisplayToken(
                branch,
                data: data,
                conditionals: conditionals,
                outcomes: outcomes,
                depth: depth + 1)
        default: return token
        }
    }

    private static func automaticWindowLabel(data: MenuBarLayoutRenderData) -> (short: String, full: String)? {
        guard let automatic = data.automatic, data.automaticText == nil else { return nil }
        let semantic: [PercentWindow] = [.session, .weekly, .scopedWeekly]
        let lanes: [MenuBarLayoutLane] = [.primary, .secondary, .tertiary]
        let extras = data.extraRateWindows.filter { data.extraTitle($0.id) != nil }
        let windows = semantic.compactMap { self.window($0, data: data) }
            + lanes.compactMap { self.laneWindow($0, data: data) } + extras.compactMap(\.window)
        // Semantic aliases must not make a single quota look like multiple windows.
        guard Set(windows).count > 1 else { return nil }
        // Match the complete selected window, never its percentage or formatted pace alone.
        let matches = semantic.filter { self.window($0, data: data) == automatic }
        let laneMatches = lanes.filter { self.laneWindow($0, data: data) == automatic }
        let extraMatches = extras.filter { $0.window == automatic }
        guard laneMatches.count + extraMatches.count <= 1 else { return nil }
        if matches.count == 1, let selected = matches.first {
            return (self.windowPrefix(selected, data: data), self.windowAccessibilityLabel(selected, data: data))
        }
        guard matches.isEmpty else { return nil }
        if laneMatches.count == 1, let lane = laneMatches.first {
            let title = data.laneLabels.label(for: lane)
            return (self.laneShortLabel(lane, data: data) ?? String(title.prefix(1)).uppercased(), title)
        }
        guard laneMatches.isEmpty, extraMatches.count == 1, let extra = extraMatches.first,
              let title = data.extraTitle(extra.id)
        else { return nil }
        let short = ProviderDescriptorRegistry.descriptor(for: data.provider).menuBarMetrics
            .namedExtraShortLabels[extra.id] ?? title
        return (short, title)
    }

    private static func renderItem(
        _ item: MenuBarLayoutToken,
        data: MenuBarLayoutRenderData,
        icon: NSImage?,
        style: TokenStyle,
        options: MenuBarLayoutRenderOptions,
        providerTintColor: NSColor? = nil)
        -> (value: NSAttributedString, accessibilityText: String?)
    {
        if let rendered = self.renderProviderTextItem(
            item,
            data: data,
            style: style,
            options: options)
        {
            return rendered
        }
        if let rendered = self.renderUsageMeterItem(
            item,
            data: data,
            style: style,
            options: options)
        {
            return rendered
        }

        switch item {
        case .icon:
            guard let icon else {
                return self.textToken(
                    self.missingValue,
                    accessibilityText: L("Icon unavailable"),
                    attributes: style.attributes)
            }
            let tintColor = providerTintColor ?? style.foregroundColor
            let attachment = NSTextAttachment()
            attachment.image = Self.attachmentImage(
                icon,
                tint: tintColor,
                isMonochrome: providerTintColor == nil)
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
        case let .percent(window):
            return self.renderPercent(window, data: data, style: style, options: options)
        case let .pace(window):
            let accessibilityPrefix = item.editorLabel(provider: data.provider)
            let pace = Self.pace(window, data: data)
            let neutralColor = Self.neutralForegroundColor(options)
            var attributes = style.attributes
            attributes[.foregroundColor] = neutralColor
            let rendered = self.optionalTextToken(
                pace,
                unavailableLabel: L("%@ unavailable", accessibilityPrefix),
                accessibilityPrefix: accessibilityPrefix,
                attributes: attributes)
            guard options.colorPace, let pace, !pace.isEmpty else { return rendered }

            var indicatorColor = neutralColor
            var isMonochrome = true
            if let delta = Self.paceDelta(window, data: data), delta.isFinite, delta != 0 {
                // Use the same rounded numeric delta as the displayed text, never its localized sign.
                let color: NSColor = delta < 0 ? .systemGreen : .systemRed
                indicatorColor = options.isStale && !options.highContrast ? color
                    .withAlphaComponent(0.5) : color
                isMonochrome = false
            }
            let result = NSMutableAttributedString(attributedString: Self.paceIndicator(
                color: indicatorColor, style: style, isMonochrome: isMonochrome))
            result.append(NSAttributedString(string: "\u{2009}", attributes: attributes))
            result.append(rendered.value)
            return (result, rendered.accessibilityText)
        case .resetCountdown, .resetAbsolute, .windowResetCountdown, .windowResetAbsolute:
            let window = item.resetWindow ?? .automatic
            let qualified = item != .resetCountdown && item != .resetAbsolute
            let label = qualified ? Self.windowAccessibilityLabel(window, data: data) : L("Resets")
            let value = MenuBarLayoutResetText(
                window: Self.window(window, data: data),
                provider: data.provider,
                now: options.now,
                absolute: item.resetIsAbsolute).value
            return self.optionalTextToken(
                value,
                unavailableLabel: qualified ? L("%@ unavailable", item.editorLabel(provider: data.provider))
                    : (item.resetIsAbsolute ? L("Reset time unavailable") : L("Reset countdown unavailable")),
                accessibilityText: value.map { qualified ? L("%@: %@", label, $0) : "\(label) \($0)" },
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
        case .costWindow:
            return self.optionalTextToken(
                data.cost30d,
                unavailableLabel: L("%@ unavailable", L("menu_bar_layout_token_cost_window")),
                attributes: style.attributes)
        case .separatorDot:
            return self.textToken("·", accessibilityText: nil, attributes: style.attributes)
        case let .separator(separator):
            return self.textToken(separator.glyph, accessibilityText: nil, attributes: style.attributes)
        case .space:
            return self.textToken(" ", accessibilityText: nil, attributes: style.attributes)
        case .hidden:
            return self.textToken("", accessibilityText: nil, attributes: style.attributes)
        case .conditional:
            // Reachable only for dangling id or depth cap; the resolver already expanded known conditionals.
            return self.textToken(
                self.missingValue,
                accessibilityText: L("menu_bar_layout_conditional_unavailable"),
                attributes: style.attributes)
        case .providerName, .accountLabel, .lanePercent, .extraPercent, .tokensPerMinute, .tokensSparkline,
             .spendAmount, .spendBudget:
            preconditionFailure("Provider text, throughput, and spend tokens should render before the main switch")
        case .usageBar, .progressBar:
            preconditionFailure("Usage meter tokens should render before the main switch")
        }
    }

    /// Character `usageBar` and graphical `progressBar` meters. Split out of
    /// `renderItem` so that switch keeps a manageable branch count.
    private static func renderUsageMeterItem(
        _ item: MenuBarLayoutToken,
        data: MenuBarLayoutRenderData,
        style: TokenStyle,
        options: MenuBarLayoutRenderOptions)
        -> (value: NSAttributedString, accessibilityText: String?)?
    {
        switch item {
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
        case let .progressBar(window):
            return self.progressBarToken(
                window,
                data: data,
                style: style,
                options: options)
        default:
            return nil
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
            estimated: data.quotaIsEstimated,
            showUsed: options.showUsed)
        let prefix = self.windowPrefix(window, data: data, showWindowLabels: options.showWindowLabels)
        let accessibilityPrefix = Self.windowAccessibilityLabel(window, data: data)
        let accessibility = resolvedValue.isAvailable
            ? L("%@ %@", accessibilityPrefix, resolvedValue.text)
            : L("%@ unavailable", accessibilityPrefix)
        return (self.prefixedValue(
            prefix,
            value: NSAttributedString(string: resolvedValue.text, attributes: style.attributes),
            attributes: style.attributes), accessibility)
    }

    private static func prefixedValue(
        _ prefix: String,
        value: NSAttributedString,
        attributes: [NSAttributedString.Key: Any]) -> NSAttributedString
    {
        guard !prefix.isEmpty else { return value }
        let result = NSMutableAttributedString(string: "\(prefix) ", attributes: attributes)
        result.addAttribute(self.windowPrefixKey, value: prefix, range: NSRange(location: 0, length: result.length))
        result.append(value)
        return result
    }

    private static func alignWindowPrefixes(in title: NSMutableAttributedString, promotedIcon: Bool = false) {
        let text = title.string as NSString
        var prefixes: [(range: NSRange, width: CGFloat)] = []
        title.enumerateAttribute(self.windowPrefixKey, in: NSRange(
            location: 0,
            length: title.length))
        { value, range, _ in
            guard value != nil else { return }
            let line = text.lineRange(for: range)
            let leading = text.substring(with: NSRange(
                location: line.location,
                length: range.location - line.location))
            guard leading.isEmpty || (promotedIcon && line.location == 0 && leading == "\u{2009}") else { return }
            let prefix = NSMutableAttributedString(attributedString: title.attributedSubstring(from: NSRange(
                location: line.location, length: NSMaxRange(range) - line.location)))
            // Measure unpadded glyph advances, including whitespace, when composing previously rendered rows.
            prefix.removeAttribute(.kern, range: NSRange(location: 0, length: prefix.length))
            let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(prefix), nil, nil, nil)
            prefixes.append((NSRange(location: NSMaxRange(range) - 1, length: 1), CGFloat(width)))
        }
        guard prefixes.count == text.components(separatedBy: "\n").count,
              let width = prefixes.map(\.width).max() else { return }
        for prefix in prefixes {
            title.addAttribute(.kern, value: width - prefix.width, range: prefix.range)
        }
    }

    private static func windowPrefix(
        _ window: PercentWindow,
        data: MenuBarLayoutRenderData,
        showWindowLabels: Bool = true) -> String
    {
        let taggedPrefix = Self.taggedSemanticLane(window, data: data)
            .flatMap { Self.laneShortLabel($0, data: data) }
        // Named lanes identify distinct allowances; Spend's currency is not a window label.
        if let taggedPrefix { return taggedPrefix }
        guard showWindowLabels || window == .spend else { return "" }
        return switch window {
        case .session:
            self.primaryLabel(data: data).flatMap(\.first).map { String($0).uppercased() }
                ?? Self.sessionPrefix(self.window(window, data: data))
        case .weekly:
            PercentWindow.weekly.providerLabel(provider: data.provider)
                .flatMap(\.first).map { String($0).uppercased() } ?? "W"
        case .scopedWeekly:
            data.scopedWeeklyTitle.map { String($0.prefix(1)).uppercased() } ?? "F"
        case .automatic:
            ""
        case .spend:
            data.spendCurrencySymbol
        }
    }

    /// A tagged lane announces its own title, so a monthly lane is never read out as "Weekly".
    private static func windowAccessibilityLabel(_ window: PercentWindow, data: MenuBarLayoutRenderData) -> String {
        if let lane = self.taggedSemanticLane(window, data: data) {
            return data.laneLabels.label(for: lane)
        }
        return switch window {
        case .session: self.primaryLabel(data: data) ?? L("Session")
        case .weekly: PercentWindow.weekly.providerLabel(provider: data.provider) ?? L("Weekly")
        case .scopedWeekly: data.scopedWeeklyTitle ?? L("Scoped weekly")
        case .automatic: L("Usage")
        case .spend: L("Spend")
        }
    }

    private static func iconAccessibilityText(data: MenuBarLayoutRenderData) -> String {
        L("%@ icon", data.providerName ?? L("Provider"))
    }

    private static func renderProviderTextItem(
        _ item: MenuBarLayoutToken,
        data: MenuBarLayoutRenderData,
        style: TokenStyle,
        options: MenuBarLayoutRenderOptions)
        -> (value: NSAttributedString, accessibilityText: String?)?
    {
        let attributes = style.attributes
        return switch item {
        case .providerName:
            self.optionalTextToken(
                data.providerName,
                unavailableLabel: L("Provider name unavailable"),
                attributes: attributes)
        case .accountLabel:
            self.optionalTextToken(
                data.accountLabel,
                unavailableLabel: L("Account unavailable"),
                attributes: attributes)
        case let .lanePercent(lane):
            self.lanePercentToken(
                lane,
                data: data,
                showUsed: options.showUsed,
                attributes: attributes)
        case let .extraPercent(id):
            self.extraPercentToken(id, data: data, showUsed: options.showUsed, attributes: attributes)
        case .spendAmount, .spendBudget:
            self.optionalTextToken(
                item == .spendBudget ? data.spendBudget : data.spendAmount,
                unavailableLabel: L("%@ unavailable", item.editorLabel(provider: data.provider)),
                accessibilityPrefix: L("Spend"),
                attributes: attributes)
        case .tokensPerMinute:
            self.optionalTextToken(
                data.tokensPerMinute.map { ProviderThroughputSection.count($0) + "/min" },
                unavailableLabel: L("%@ unavailable", L("Tokens / min")),
                attributes: attributes)
        case .tokensSparkline:
            self.sparklineToken(data: data, style: style, options: options)
        default:
            nil
        }
    }

    private static func lanePercentToken(
        _ lane: MenuBarLayoutLane,
        data: MenuBarLayoutRenderData,
        showUsed: Bool,
        attributes: [NSAttributedString.Key: Any])
        -> (value: NSAttributedString, accessibilityText: String?)
    {
        let rateWindow = Self.laneWindow(lane, data: data)
        let resolvedValue = Self.percentValue(
            window: .automatic,
            rateWindow: rateWindow,
            automaticText: nil,
            estimated: data.quotaIsEstimated,
            showUsed: showUsed)
        let label = data.laneLabels.label(for: lane)
        let accessibility = resolvedValue.isAvailable
            ? L("%@ %@", label, resolvedValue.text)
            : L("%@ unavailable", label)
        let display = Self.laneShortLabel(lane, data: data)
            .map { "\($0) \(resolvedValue.text)" } ?? resolvedValue.text
        return self.textToken(display, accessibilityText: accessibility, attributes: attributes)
    }

    private static func extraPercentToken(
        _ id: String,
        data: MenuBarLayoutRenderData,
        showUsed: Bool,
        attributes: [NSAttributedString.Key: Any])
        -> (value: NSAttributedString, accessibilityText: String?)
    {
        let title = data.extraTitle(id) ?? L("Usage")
        let resolvedValue = self.percentValue(
            window: .automatic,
            rateWindow: data.extraWindow(id)?.window,
            automaticText: nil,
            estimated: data.quotaIsEstimated,
            showUsed: showUsed)
        let accessibility = resolvedValue.isAvailable
            ? L("%@ %@", title, resolvedValue.text)
            : L("%@ unavailable", title)
        let shortLabel = ProviderDescriptorRegistry.descriptor(for: data.provider)
            .menuBarMetrics.namedExtraShortLabels[id]
        return self.textToken(
            L("%@ %@", shortLabel ?? title, resolvedValue.text),
            accessibilityText: accessibility,
            attributes: attributes)
    }

    private static func percentValue(
        window: PercentWindow,
        rateWindow: MenuBarLayoutRenderWindow?,
        automaticText: String?,
        estimated: Bool,
        showUsed: Bool)
        -> (text: String, isAvailable: Bool)
    {
        if window == .automatic, let automaticText {
            // Provider-supplied balance text overrides only the automatic lane.
            return (automaticText, true)
        }
        if let rateWindow {
            let percent = showUsed ? rateWindow.usedPercent : rateWindow.remainingPercent
            return ("\(estimated ? "~" : "")\(UsageFormatter.percentString(percent))", true)
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
        offsetImage.isTemplate = image.isTemplate
        return offsetImage
    }

    static func attachmentImage(_ image: NSImage, tint: NSColor, isMonochrome: Bool = true) -> NSImage {
        guard image.isTemplate else { return image }

        // NSTextAttachment draws an NSImage directly instead of through an image cell, so AppKit does not
        // apply template tinting here. Keep a template image for monochrome status-item semantics while drawing its
        // mask with the dynamic foreground color. For provider-colored marks, keep isTemplate false so AppKit preserves
        // the tint.
        let tintedImage = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        tintedImage.isTemplate = isMonochrome
        return tintedImage
    }

    private static func neutralForegroundColor(_ options: MenuBarLayoutRenderOptions) -> NSColor {
        options.highContrast ? .labelColor : options.isStale ? .secondaryLabelColor : .controlTextColor
    }

    /// Provider color is decoration; native monochrome owns stale, selected and accessible states.
    static func effectiveProviderTintColor(
        for provider: UsageProvider,
        options: MenuBarLayoutRenderOptions) -> NSColor?
    {
        guard options.colorByProvider, !options.isHighlighted, !options.isStale, !options.highContrast,
              !options.appearanceName.localizedCaseInsensitiveContains("accessibility")
        else { return nil }
        let accent = ProviderAccentPalette.color(for: provider)
        guard self.meetsAppearanceContrast(accent: accent, appearanceName: options.appearanceName) else { return nil }
        return NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
    }

    static func meetsAppearanceContrast(accent: ProviderColor, appearanceName: String) -> Bool {
        let isDark = appearanceName.localizedCaseInsensitiveContains("dark")
        guard isDark || appearanceName.localizedCaseInsensitiveContains("aqua")
            || appearanceName.localizedCaseInsensitiveContains("light") else { return false }
        // Conservative reference backgrounds allow more translucency than pure black/white.
        // Require lighter accents on dark bars and darker accents on light bars.
        let gray = isDark ? 0.25 : 0.85
        let background = self.relativeLuminance(of: ProviderColor(red: gray, green: gray, blue: gray))
        let luminance = self.relativeLuminance(of: accent)
        return isDark ? (luminance + 0.05) / (background + 0.05) >= 2
            : (background + 0.05) / (luminance + 0.05) >= 2
    }

    static func relativeLuminance(of color: ProviderColor) -> Double {
        func linear(_ value: Double) -> Double {
            let clamped = min(1, max(0, value))
            return clamped <= 0.04045 ? clamped / 12.92 : pow((clamped + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
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
        case .spend: data.spend
        }
    }

    private static func laneWindow(
        _ lane: MenuBarLayoutLane,
        data: MenuBarLayoutRenderData)
        -> MenuBarLayoutRenderWindow?
    {
        switch lane {
        case .primary: data.primary
        case .secondary: data.secondary
        case .tertiary: data.tertiary
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
        case .spend: data.spendPace
        }
    }

    private static func paceDelta(
        _ window: PercentWindow,
        data: MenuBarLayoutRenderData) -> Double?
    {
        switch window {
        case .session: data.metrics.sessionPaceDelta
        case .weekly: data.metrics.weeklyPaceDelta
        case .automatic: data.metrics.automaticPaceDelta
        case .spend: data.metrics.spendPaceDelta
        case .scopedWeekly: nil
        }
    }

    private static func primaryLabel(data: MenuBarLayoutRenderData) -> String? {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: data.provider)
        if let label = descriptor.presentation.menuBarLayoutPrimaryLabel { return L(label) }
        let lane: MenuBarLayoutLane = descriptor.presentation.primarySemanticWindow == .session ? .primary : .secondary
        let label = data.laneLabels.label(for: lane)
        let renamedTaggedLane = !descriptor.menuBarMetrics.laneShortLabels.isEmpty
            && label != MenuBarLayoutLaneLabels(provider: data.provider, snapshot: nil).label(for: lane)
        guard (descriptor.metadata.usesDetailBackedWindow && data.session?.windowMinutes == nil) || renamedTaggedLane
        else { return nil }
        return label
    }

    private static func sessionPrefix(_ window: MenuBarLayoutRenderWindow?) -> String {
        guard let minutes = window?.windowMinutes, minutes > 0 else { return "S" }
        guard minutes.isMultiple(of: 60) else { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}

extension MenuBarLayoutRenderer {
    private static func fontSize(size: MenuBarLayoutSize, isStacked: Bool) -> CGFloat {
        switch size {
        case .small: isStacked ? 8 : 11
        case .regular: isStacked ? 9 : NSFont.systemFontSize
        case .large: isStacked ? 10 : 14
        }
    }

    private static func iconHeight(size: MenuBarLayoutSize, isStacked: Bool) -> CGFloat {
        if isStacked {
            return size == .small ? 8 : 9
        }
        return size == .small ? 14 : 18
    }

    private static func sparklineToken(
        data: MenuBarLayoutRenderData,
        style: TokenStyle,
        options: MenuBarLayoutRenderOptions)
        -> (value: NSAttributedString, accessibilityText: String?)
    {
        guard let graph = data.tokensSparkline,
              let image = graph.image(height: style.iconHeight, highlighted: options.isHighlighted)
        else {
            return self.textToken(
                self.missingValue,
                accessibilityText: L("%@ unavailable", L("Tokens / min graph")),
                attributes: style.attributes)
        }
        let attachment = NSTextAttachment()
        attachment.image = Self.attachmentImage(image, tint: style.foregroundColor)
        attachment.bounds = NSRect(
            x: 0,
            y: ((style.font.capHeight - style.iconHeight) / 2).rounded(),
            width: image.size.width,
            height: style.iconHeight)
        let value = NSMutableAttributedString(attachment: attachment)
        value.addAttributes(style.attributes, range: NSRange(location: 0, length: value.length))
        return (value, L("Tokens per minute, latest %@", graph.latest.map(ProviderThroughputSection.count) ?? "—"))
    }

    /// Provider-declared menu bar tag for a lane; nil keeps the lane's percentage bare. A snapshot-dependent
    /// lane label (Cursor's X Subscription "Weekly" pool) means the static tag no longer names that lane.
    private static func laneShortLabel(_ lane: MenuBarLayoutLane, data: MenuBarLayoutRenderData) -> String? {
        let labels = ProviderDescriptorRegistry.descriptor(for: data.provider).menuBarMetrics.laneShortLabels
        guard !labels.isEmpty else { return nil }
        let staticLabels = MenuBarLayoutLaneLabels(provider: data.provider, snapshot: nil)
        guard data.laneLabels.label(for: lane) == staticLabels.label(for: lane) else { return nil }
        return switch lane {
        case .primary: labels[.primary]
        case .secondary: labels[.secondary]
        case .tertiary: labels[.tertiary]
        }
    }

    /// The tagged lane backing a session/weekly percentage, so a provider with explicit lane tags never falls
    /// back to colliding first-letter prefixes; nil when the window maps to no tagged lane.
    private static func taggedSemanticLane(
        _ window: PercentWindow,
        data: MenuBarLayoutRenderData) -> MenuBarLayoutLane?
    {
        let presentation = ProviderDescriptorRegistry.descriptor(for: data.provider).presentation
        let primaryWindow = PercentWindow.forSemanticWindow(presentation.primarySemanticWindow)
        let lane: MenuBarLayoutLane? = if window == primaryWindow {
            .primary
        } else if window == PercentWindow.forSemanticWindow(presentation.secondarySemanticWindow) {
            .secondary
        } else {
            nil
        }
        guard let lane, self.laneShortLabel(lane, data: data) != nil else { return nil }
        return lane
    }
}

extension MenuBarLayoutRenderer {
    /// Graphical progress bar for one semantic window, embedded as an `NSTextAttachment` so the
    /// status-item title keeps surrounding countdown text in the same line. The bar is a pre-tinted
    /// bitmap (AppKit does not template-tint attachments), so it is cached by fill/style like the
    /// rest of the title via `MenuBarLayoutTitleCache`.
    private static func progressBarToken(
        _ window: PercentWindow,
        data: MenuBarLayoutRenderData,
        style: TokenStyle,
        options: MenuBarLayoutRenderOptions)
        -> (value: NSAttributedString, accessibilityText: String?)
    {
        let accessibilityPrefix = self.windowAccessibilityLabel(window, data: data)
        // Balance-backed automatic lanes (DeepSeek, DeepInfra, …) override the automatic percent with
        // text because the quota percent is meaningless. Never turn that override into a fake bar.
        if window == .automatic, let automaticText = data.automaticText {
            return self.textToken(
                automaticText,
                accessibilityText: L("%@ %@", accessibilityPrefix, automaticText),
                attributes: style.attributes)
        }
        guard let rateWindow = self.window(window, data: data) else {
            return self.textToken(
                self.missingValue,
                accessibilityText: L("%@ unavailable", accessibilityPrefix),
                attributes: style.attributes)
        }
        let percent = options.showUsed ? rateWindow.usedPercent : rateWindow.remainingPercent
        let clamped = percent.clamped(to: 0...100)
        let barSize = self.progressBarSize(size: options.size, font: style.font)
        let image = self.progressBarImage(
            fillPercent: clamped,
            size: barSize,
            tint: style.foregroundColor,
            stale: options.isStale)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(
            x: 0,
            y: self.attachmentYOrigin(height: barSize.height, style: style),
            width: barSize.width,
            height: barSize.height)

        // Keep the window label ("5h" / "W") beside the bar so stacked rows stay unambiguous.
        let prefix = self.windowPrefix(window, data: data)

        let result = self.prefixedValue(
            prefix, value: self.attachmentText(attachment, style: style), attributes: style.attributes)

        let percentText = self.percentValue(
            window: window,
            rateWindow: rateWindow,
            automaticText: nil,
            estimated: data.quotaIsEstimated,
            showUsed: options.showUsed).text
        let accessibility = L("%@ %@", accessibilityPrefix, percentText)
        return (result, accessibility)
    }

    private static func paceIndicator(color: NSColor, style: TokenStyle, isMonochrome: Bool) -> NSAttributedString {
        let height = style.font.capHeight
        let size = NSSize(width: height / 2, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }
        image.isTemplate = isMonochrome
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(
            x: 0,
            y: Self.attachmentYOrigin(height: size.height, style: style),
            width: size.width,
            height: size.height)
        let value = NSMutableAttributedString(attributedString: Self.attachmentText(attachment, style: style))
        value.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: value.length))
        return value
    }

    private static func progressBarSize(size: MenuBarLayoutSize, font: NSFont) -> NSSize {
        let height = max(5, (font.capHeight * 0.55).rounded())
        let width: CGFloat = if font.pointSize <= 9 {
            32
        } else if size == .small {
            36
        } else {
            44
        }
        return NSSize(width: width, height: height)
    }

    private static func progressBarImage(
        fillPercent: Double,
        size: NSSize,
        tint: NSColor,
        stale: Bool)
        -> NSImage
    {
        // Graphical counterpart to the persisted three-segment character usageBar.
        let alpha: CGFloat = stale ? 0.55 : 1.0
        let segmentCount = 5
        let gap: CGFloat = 2
        let corner = min(size.height, 3) / 2
        return NSImage(size: size, flipped: false) { rect in
            let segmentWidth = max(2, (rect.width - gap * CGFloat(segmentCount - 1)) / CGFloat(segmentCount))
            let filled = Int((fillPercent.clamped(to: 0...100) / 100 * Double(segmentCount)).rounded())
            for index in 0..<segmentCount {
                let x = CGFloat(index) * (segmentWidth + gap)
                let box = NSRect(x: x, y: 0, width: segmentWidth, height: rect.height)
                let path = NSBezierPath(roundedRect: box, xRadius: corner, yRadius: corner)
                if index < filled {
                    tint.withAlphaComponent(alpha).setFill()
                    path.fill()
                } else {
                    tint.withAlphaComponent(0.45 * alpha).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
            return true
        }
    }

    /// Attachment runs drop `baselineOffset` so the glyph shift is not applied twice. The same
    /// shift is re-applied through `bounds.origin.y`, which is what AppKit actually uses to place
    /// `NSTextAttachment` images — without it the meter sits on the unshifted baseline and looks
    /// vertically off-center from the surrounding text (especially stacked rows at -3pt).
    private static func attachmentText(_ attachment: NSTextAttachment, style: TokenStyle) -> NSAttributedString {
        let value = NSMutableAttributedString(attachment: attachment)
        value.addAttributes(style.attributes, range: NSRange(location: 0, length: value.length))
        value.removeAttribute(.baselineOffset, range: NSRange(location: 0, length: value.length))
        return value
    }

    /// Centers a meter of `height` on the text cap band, then follows the run's `baselineOffset`
    /// (stacked/single-line base plus the user's vertical adjustment).
    private static func attachmentYOrigin(height: CGFloat, style: TokenStyle) -> CGFloat {
        let shift = (style.attributes[.baselineOffset] as? NSNumber)?.doubleValue ?? 0
        return ((style.font.capHeight - height) / 2).rounded() + CGFloat(shift)
    }
}

extension MenuBarLayoutConditional {
    /// Left-fold over clauses; a predicate whose datum is unavailable evaluates false.
    ///
    /// `now` is a parameter rather than a field on `MenuBarLayoutRenderData` because the render data is
    /// a cache key: putting a constantly ticking clock in it would defeat `MenuBarLayoutTitleCache`.
    func evaluatesTrue(data: MenuBarLayoutRenderData, now: Date) -> Bool {
        guard let first = self.clauses.first else { return false }
        var result = Self.test(first.predicate, data: data, now: now)
        for clause in self.clauses.dropFirst() {
            let value = Self.test(clause.predicate, data: data, now: now)
            switch clause.combinator {
            case .or: result = result || value
            case .and, .none: result = result && value
            }
        }
        return result
    }

    private static func test(
        _ predicate: MenuBarConditionalPredicate,
        data: MenuBarLayoutRenderData,
        now: Date)
        -> Bool
    {
        guard let value = Self.value(for: predicate, in: data, now: now) else { return false }
        return predicate.comparison.evaluate(value, predicate.threshold)
    }

    // swiftlint:disable cyclomatic_complexity
    /// nil == the datum is unavailable, so the predicate evaluates false instead of comparing a
    /// fabricated zero. Percent and reset readings come from the render windows; pace, run-out, balance
    /// and cost come from `data.metrics`, whose display strings cannot be compared numerically.
    private static func value(
        for predicate: MenuBarConditionalPredicate,
        in data: MenuBarLayoutRenderData,
        now: Date)
        -> Double?
    {
        switch predicate.metric {
        case .session: self.percent(data.session, predicate.direction)
        case .weekly: self.percent(data.weekly, predicate.direction)
        case .scopedWeekly: self.percent(data.scopedWeekly, predicate.direction)
        case .automatic: self.percent(data.automatic, predicate.direction)
        case .spend: self.percent(data.spend, predicate.direction)
        case .primaryLane: self.percent(data.primary, predicate.direction)
        case .secondaryLane: self.percent(data.secondary, predicate.direction)
        case .tertiaryLane: self.percent(data.tertiary, predicate.direction)
        case .sessionResetsIn: self.hoursUntilReset(data.session, now: now)
        case .weeklyResetsIn: self.hoursUntilReset(data.weekly, now: now)
        case .scopedWeeklyResetsIn: self.hoursUntilReset(data.scopedWeekly, now: now)
        case .automaticResetsIn: self.hoursUntilReset(data.automatic, now: now)
        case .spendResetsIn: self.hoursUntilReset(data.spend, now: now)
        case .sessionPace: data.metrics.sessionPaceDelta
        case .weeklyPace: data.metrics.weeklyPaceDelta
        case .automaticPace: data.metrics.automaticPaceDelta
        case .spendPace: data.metrics.spendPaceDelta
        case .runsOutIn: data.metrics.runsOutMinutes.map { Double($0) / 60 }
        case .balance: predicate.direction == .used
            ? data.metrics.balanceUsedUSD
            : data.metrics.balanceRemainingUSD
        case .costToday: data.metrics.costTodayUSD
        case .costWindow: data.metrics.cost30dUSD
        case .spendAmount: predicate.direction == .used
            ? data.metrics.spendUsedUSD
            : data.metrics.spendRemainingUSD
        }
    }

    // swiftlint:enable cyclomatic_complexity

    private static func percent(
        _ window: MenuBarLayoutRenderWindow?,
        _ direction: MenuBarConditionalDirection)
        -> Double?
    {
        guard let window else { return nil }
        return direction == .used ? window.usedPercent : window.remainingPercent
    }

    /// Hours until the window resets. A window with no reset timestamp — or one whose reset already
    /// passed, meaning the snapshot has not caught up yet — has no countdown to compare, so the
    /// predicate evaluates false rather than firing a "resets soon" branch off stale data.
    private static func hoursUntilReset(_ window: MenuBarLayoutRenderWindow?, now: Date) -> Double? {
        guard let resetsAt = window?.resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        return seconds / 3600
    }
}
