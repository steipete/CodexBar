import AppKit
import CodexBarCore

/// One reading for every Overview provider: the average of each provider's tightest limit, plus whichever providers
/// are close to stopping. Quotas differ, so the average is only a glance; the near-limit list is what stops it hiding
/// one exhausted provider among healthy ones.
struct MenuBarUsageTotal: Equatable {
    struct Entry: Equatable {
        let provider: UsageProvider
        let remainingPercent: Double
        let isStale: Bool
        var runsOutMinutes: Int?

        var raisesWarning: Bool {
            guard !self.isStale else { return false }
            return self.remainingPercent <= MenuBarUsageTotal.nearLimitRemainingPercent
                || (self.runsOutMinutes ?? .max) <= MenuBarUsageTotal.imminentRunsOutMinutes
        }
    }

    /// The Overview's red rule: at most this share left, or a forecast this close.
    static let nearLimitRemainingPercent: Double = 10
    static let imminentRunsOutMinutes = 60

    let averageRemainingPercent: Double
    let providerCount: Int
    /// True only when nothing fresher backs the average.
    let isStale: Bool
    /// Tightest first. Equal limits keep the caller's provider order, so the warning does not flip between refreshes.
    /// Stale data never raises a warning.
    let nearLimit: [Entry]

    init?(entries: [Entry]) {
        guard !entries.isEmpty else { return nil }
        self.averageRemainingPercent = entries.map(\.remainingPercent).reduce(0, +) / Double(entries.count)
        self.providerCount = entries.count
        self.isStale = entries.allSatisfy(\.isStale)
        self.nearLimit = entries.enumerated()
            .filter(\.element.raisesWarning)
            .sorted { lhs, rhs in
                lhs.element.remainingPercent == rhs.element.remainingPercent
                    ? lhs.offset < rhs.offset
                    : lhs.element.remainingPercent < rhs.element.remainingPercent
            }
            .map(\.element)
    }

    /// Every quota the snapshot actually measured. Semantic lanes can omit one (Cursor's Total), and a named window
    /// with unknown usage carries a placeholder percent. A window past its reset no longer describes the quota; this is
    /// the same rule the Codex projection applies before a window can reach the menu bar.
    static func measuredWindows(snapshot: UsageSnapshot, now: Date) -> [RateWindow] {
        let named = snapshot.extraRateWindows?.filter(\.usageKnown).map(\.window) ?? []
        return ([snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self) + named)
            .filter { !$0.isSyntheticPlaceholder && !self.isPastReset($0.resetsAt, now: now) }
    }

    private static func isPastReset(_ resetsAt: Date?, now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    /// The limit that stops a provider next. A balance-backed automatic lane has no meaningful percent, so a provider
    /// with only that lane reports no quota at all, and its raw windows are not quotas either.
    @MainActor
    static func tightestRemainingPercent(
        data: MenuBarLayoutRenderData,
        measured: [RateWindow] = [],
        now: Date = .init())
        -> Double?
    {
        var windows: [PercentWindow] = [.session, .weekly, .scopedWeekly]
        var remaining = measured.map(\.remainingPercent)
        if data.automaticText == nil {
            windows.append(.automatic)
        } else {
            remaining = []
        }
        let lanes = windows.compactMap { MenuBarLayoutRenderer.window($0, data: data) }
            .filter { !self.isPastReset($0.resetsAt, now: now) }
            .map(\.remainingPercent)
        return (lanes + remaining).min()
    }
}

extension MenuBarLayoutRenderer {
    struct UsageTotalMemoKey: Equatable {
        let total: MenuBarUsageTotal?
        let hasLogo: Bool
        let size: MenuBarLayoutSize
        let highContrast: Bool
        let showUsed: Bool
        let verticalAdjustment: Int
    }

    /// Keeps image identity between identical readings so the status item skips a pointless redraw.
    func usageTotal(
        _ total: MenuBarUsageTotal?,
        logo: NSImage?,
        options: MenuBarLayoutRenderOptions)
        -> MenuBarLayoutRenderedTitle
    {
        let key = UsageTotalMemoKey(
            total: total,
            hasLogo: logo != nil,
            size: options.size,
            highContrast: options.highContrast,
            showUsed: options.showUsed,
            verticalAdjustment: options.verticalAdjustment)
        if let memo = self.usageTotalMemo, memo.key == key {
            return memo.rendered
        }
        let rendered = Self.renderUsageTotal(total, logo: logo, options: options)
        self.usageTotalMemo = (key, rendered)
        return rendered
    }

    private static let usageTotalMeterSize = NSSize(width: 24, height: 6)
    private static let usageTotalLogoSide: CGFloat = 15
    private static let usageTotalCapsuleHeight: CGFloat = 15
    private static let usageTotalGap: CGFloat = 4
    private static let usageTotalCanvasHeight: CGFloat = 22
    private static let usageTotalStaleAlpha: CGFloat = 0.5
    /// A fixed red: white text keeps its contrast on any wallpaper or menu bar tint.
    private static let usageTotalCapsuleColor = NSColor(srgbRed: 0.84, green: 0.15, blue: 0.13, alpha: 1)

    /// Calm: `[meter] 62%`. Near a limit: `[meter] [logo] (8%)`. The meter always shows the total, and the number
    /// beside
    /// it belongs to whatever sits immediately left of it. Everything neutral is one template image so AppKit owns
    /// tinting and inactive-display dimming; only the capsule carries its own colour, and the logo makes the warning
    /// readable without it.
    static func renderUsageTotal(
        _ total: MenuBarUsageTotal?,
        logo: NSImage?,
        options: MenuBarLayoutRenderOptions)
        -> MenuBarLayoutRenderedTitle
    {
        let fontSize = Self.fontSize(size: options.size, isStacked: false)
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let display = { (remaining: Double) in options.showUsed ? 100 - remaining : remaining }
        let warning = total?.nearLimit.first
        let neutralText: String? = if warning != nil {
            nil
        } else {
            total.map { Self.usageTotalPercent(display($0.averageRemainingPercent)) } ?? Self.missingValue
        }
        let neutral = Self.usageTotalNeutralImage(
            fill: total.map { display($0.averageRemainingPercent) } ?? 0,
            logo: warning == nil ? nil : logo,
            text: neutralText,
            alpha: total?.isStale == true ? Self.usageTotalStaleAlpha : 1,
            options: options)
        let accessibilityLabel = Self.usageTotalAccessibilityLabel(total, showUsed: options.showUsed)

        let title = NSMutableAttributedString()
        // High contrast opts out of the template's inactive-display dimming, so the neutral part is pre-tinted.
        if options.highContrast {
            title.append(Self.usageTotalAttachment(
                Self.attachmentImage(neutral, tint: .labelColor, isMonochrome: false),
                font: font))
        }
        if let warning {
            if title.length > 0 {
                title.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
            }
            title.append(Self.usageTotalAttachment(
                Self.usageTotalCapsule(text: Self.usageTotalPercent(display(warning.remainingPercent)), font: font),
                font: font,
                verticalAdjustment: options.verticalAdjustment))
        }
        return MenuBarLayoutRenderedTitle(
            attributedTitle: title,
            accessibilityLabel: accessibilityLabel,
            leadingIcon: options.highContrast ? nil : neutral)
    }

    private static func usageTotalPercent(_ percent: Double) -> String {
        "\(Int(percent.clamped(to: 0...100).rounded()))%"
    }

    private static func usageTotalAccessibilityLabel(_ total: MenuBarUsageTotal?, showUsed: Bool) -> String {
        guard let total else {
            return L("%@ unavailable", L("merged_icon_source_all_providers"))
        }
        let describe = { (remaining: Double) in
            showUsed
                ? L("%@ used", Self.usageTotalPercent(100 - remaining))
                : L("%@ left", Self.usageTotalPercent(remaining))
        }
        let warnings = total.nearLimit.map { entry in
            L(
                "menu_bar_total_near_limit_accessibility",
                L(ProviderDescriptorRegistry.descriptor(for: entry.provider).metadata.displayName),
                describe(entry.remainingPercent))
        }
        return (warnings + [L("menu_bar_total_accessibility", describe(total.averageRemainingPercent))])
            .joined(separator: ", ")
    }

    private static func usageTotalNeutralImage(
        fill: Double,
        logo: NSImage?,
        text: String?,
        alpha: CGFloat,
        options: MenuBarLayoutRenderOptions)
        -> NSImage
    {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: Self.fontSize(size: options.size, isStacked: false), weight: .regular)
        let verticalAdjustment = CGFloat(options.verticalAdjustment)
        let meter = Self.usageTotalMeterSize
        let gap = Self.usageTotalGap
        let logoSide = Self.usageTotalLogoSide
        let height = Self.usageTotalCanvasHeight
        let label = text
            .map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: NSColor.black]) }
        let labelWidth = label.map { ceil($0.size().width) } ?? 0
        let width = meter.width + (logo == nil ? 0 : gap + logoSide) + (label == nil ? 0 : gap + labelWidth)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let context = NSGraphicsContext.current?.cgContext
            // This image already fills the 22 pt canvas; shift its content instead of adding padding.
            context?.saveGState()
            defer { context?.restoreGState() }
            context?.translateBy(x: 0, y: verticalAdjustment)
            context?.setAlpha(alpha)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { context?.endTransparencyLayer() }

            let track = NSRect(
                x: 0,
                y: ((height - meter.height) / 2).rounded(),
                width: meter.width,
                height: meter.height)
            let radius = meter.height / 2
            NSColor.black.withAlphaComponent(0.32).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            if fill > 0 {
                var filled = track
                // A nonzero total always shows a sliver; only a true zero leaves the track empty.
                filled.size.width = max(meter.height, meter.width * fill.clamped(to: 0...100) / 100)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
            }

            var x = meter.width + gap
            if let logo {
                logo.draw(in: NSRect(x: x, y: ((height - logoSide) / 2).rounded(), width: logoSide, height: logoSide))
                x += logoSide + gap
            }
            // Centres the cap band on the canvas, the same line the meter sits on.
            label?.draw(at: NSPoint(x: x, y: ((height - font.capHeight) / 2).rounded() + font.descender))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func usageTotalCapsule(text: String, font: NSFont) -> NSImage {
        let height = Self.usageTotalCapsuleHeight
        let capsuleFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize - 1, weight: .semibold)
        let label = NSAttributedString(string: text, attributes: [.font: capsuleFont, .foregroundColor: NSColor.white])
        let width = ceil(label.size().width) + 10
        let color = Self.usageTotalCapsuleColor
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
            label.draw(at: NSPoint(x: 5, y: ((height - capsuleFont.capHeight) / 2).rounded() + capsuleFont.descender))
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func usageTotalAttachment(
        _ image: NSImage,
        font: NSFont,
        verticalAdjustment: Int = 0) -> NSAttributedString
    {
        let height = Self.usageTotalCanvasHeight
        // Keep line metrics fixed; NSButton can otherwise recenter away part of a baseline offset.
        let originalOrigin = ((font.capHeight - image.size.height) / 2).rounded()
        let paddedOrigin = ((font.capHeight - height) / 2).rounded()
        let padding = originalOrigin - paddedOrigin
        let attachmentImage = NSImage(size: NSSize(width: image.size.width, height: height), flipped: false) { _ in
            image.draw(in: NSRect(
                x: 0,
                y: padding + CGFloat(verticalAdjustment),
                width: image.size.width,
                height: image.size.height))
            return true
        }
        attachmentImage.isTemplate = image.isTemplate
        let attachment = NSTextAttachment()
        attachment.image = attachmentImage
        attachment.bounds = NSRect(
            x: 0,
            y: ((font.capHeight - attachmentImage.size.height) / 2).rounded(),
            width: attachmentImage.size.width,
            height: attachmentImage.size.height)
        let value = NSMutableAttributedString(attachment: attachment)
        value.addAttribute(.font, value: font, range: NSRange(location: 0, length: value.length))
        return value
    }
}
