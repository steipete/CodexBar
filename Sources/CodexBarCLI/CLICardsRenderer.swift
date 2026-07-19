import CodexBarCore
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

struct CLICardMetric: Sendable, Equatable {
    let label: String
    let remainingPercent: Double
    let resetText: String?
    let resetAt: Date?
    let detailText: String?

    init(
        label: String,
        remainingPercent: Double,
        resetText: String?,
        resetAt: Date? = nil,
        detailText: String? = nil)
    {
        self.label = label
        self.remainingPercent = remainingPercent
        self.resetText = resetText
        self.resetAt = resetAt
        self.detailText = detailText
    }
}

struct CLICardModel: Sendable, Equatable {
    let provider: UsageProvider
    let title: String
    let sourceLabel: String
    let planBadge: String?
    let accountLine: String?
    let isActive: Bool
    let accountProblem: String?
    let infoLines: [String]
    let metrics: [CLICardMetric]
    let extraLines: [String]
    let statusLine: String?

    init(
        provider: UsageProvider,
        title: String,
        sourceLabel: String,
        planBadge: String?,
        accountLine: String?,
        isActive: Bool = false,
        accountProblem: String? = nil,
        infoLines: [String],
        metrics: [CLICardMetric],
        extraLines: [String],
        statusLine: String?)
    {
        self.provider = provider
        self.title = title
        self.sourceLabel = sourceLabel
        self.planBadge = planBadge
        self.accountLine = accountLine
        self.isActive = isActive
        self.accountProblem = accountProblem
        self.infoLines = infoLines
        self.metrics = metrics
        self.extraLines = extraLines
        self.statusLine = statusLine
    }
}

struct CLICardFailure: Sendable, Equatable {
    let provider: UsageProvider
    let accountLabel: String?
    let message: String
}

struct CLICardBuildInput: Sendable {
    let provider: UsageProvider
    let snapshot: UsageSnapshot
    let credits: CreditsSnapshot?
    let source: String
    let status: ProviderStatusPayload?
    let notes: [String]
    let useColor: Bool
    let resetStyle: ResetTimeDisplayStyle
    let weeklyWorkDays: Int?
    let now: Date
}

enum CLICardsRenderer {
    static let minCardWidth = 38
    static let maxCardWidth = 42
    static let cardGap = 2

    static func terminalColumnCount() -> Int {
        if let value = terminalColumnCountFromTTY(), value > 0 {
            return value
        }
        if let columns = ProcessInfo.processInfo.environment["COLUMNS"],
           let value = Int(columns.trimmingCharacters(in: .whitespacesAndNewlines)),
           value > 0
        {
            return value
        }
        return 80
    }

    private static func terminalColumnCountFromTTY(fileDescriptor: Int32 = STDOUT_FILENO) -> Int? {
        guard isatty(fileDescriptor) == 1 else { return nil }
        var windowSize = winsize(ws_row: 0, ws_col: 0, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(fileDescriptor, UInt(TIOCGWINSZ), &windowSize) == 0 else { return nil }
        let columns = Int(windowSize.ws_col)
        return columns > 0 ? columns : nil
    }

    static func columnCount(terminalWidth: Int, minCardWidth: Int = Self.minCardWidth) -> Int {
        let usable = max(minCardWidth, terminalWidth)
        return max(1, (usable + Self.cardGap) / (minCardWidth + Self.cardGap))
    }

    static func cardWidth(terminalWidth: Int, columns: Int) -> Int {
        let totalGaps = (columns - 1) * Self.cardGap
        let availableWidth = max(1, (terminalWidth - totalGaps) / columns)
        return min(Self.maxCardWidth, availableWidth)
    }

    static func makeCard(_ input: CLICardBuildInput) -> CLICardModel {
        let provider = input.provider
        let snapshot = input.snapshot
        let displayName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let context = RenderContext(
            header: displayName,
            status: input.status,
            useColor: input.useColor,
            resetStyle: input.resetStyle,
            weeklyWorkDays: input.weeklyWorkDays,
            notes: input.notes)
        let infoLines = CLIRenderer.collectCardInfoLines(
            provider: provider,
            snapshot: snapshot,
            credits: input.credits,
            notes: input.notes,
            useColor: input.useColor,
            now: input.now)
        let metrics = CLIRenderer.collectCardMetrics(
            provider: provider,
            snapshot: snapshot,
            resetStyle: input.resetStyle,
            now: input.now)
        let extraLines = CLIRenderer.collectCardExtraLines(
            provider: provider,
            snapshot: snapshot,
            credits: input.credits,
            context: context,
            now: input.now)
        let statusLine: String?
        if let status = input.status {
            let line = "Status: \(status.indicator.label)\(status.descriptionSuffix)"
            statusLine = CLIRenderer.colorizeStatusLine(line, indicator: status.indicator, useColor: input.useColor)
        } else {
            statusLine = nil
        }
        return CLICardModel(
            provider: provider,
            title: displayName,
            sourceLabel: Self.normalizedSourceLabel(input.source),
            planBadge: CLIRenderer.planBadgeText(provider: provider, snapshot: snapshot),
            accountLine: snapshot.accountEmail(for: provider),
            infoLines: infoLines,
            metrics: metrics,
            extraLines: extraLines,
            statusLine: statusLine)
    }

    static func makeClaudeSwapCard(
        account: ProviderAccountUsageSnapshot,
        renderOptions: CLIClaudeSwapCardsRenderOptions) -> CLICardModel
    {
        let sanitizedLabel = CLIClaudeSwapText.sanitizeLabel(account.displayLabel)
        let label = sanitizedLabel.isEmpty
            ? CLIClaudeSwapText.sanitizeLabel("Account \(account.id.opaqueID)")
            : sanitizedLabel
        let problem = account.error.map(CLIClaudeSwapText.sanitizeDiagnostic)
        if let snapshot = account.snapshot {
            let base = Self.makeCard(CLICardBuildInput(
                provider: .claude,
                snapshot: snapshot,
                credits: nil,
                source: ClaudeSwapAccountProjection.sourceLabel,
                status: renderOptions.status,
                notes: [],
                useColor: renderOptions.useColor,
                resetStyle: renderOptions.resetStyle,
                weeklyWorkDays: renderOptions.weeklyWorkDays,
                now: renderOptions.now))
            return CLICardModel(
                provider: base.provider,
                title: base.title,
                sourceLabel: base.sourceLabel,
                planBadge: nil,
                accountLine: label,
                isActive: account.isActive,
                accountProblem: problem,
                infoLines: base.infoLines,
                metrics: base.metrics,
                extraLines: base.extraLines,
                statusLine: base.statusLine)
        }

        let statusLine: String? = renderOptions.status.map { status in
            let line = "Status: \(status.indicator.label)\(status.descriptionSuffix)"
            return CLIRenderer.colorizeStatusLine(
                line,
                indicator: status.indicator,
                useColor: renderOptions.useColor)
        }
        return CLICardModel(
            provider: .claude,
            title: ProviderDescriptorRegistry.descriptor(for: .claude).metadata.displayName,
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel,
            planBadge: nil,
            accountLine: label,
            isActive: account.isActive,
            accountProblem: problem,
            infoLines: [],
            metrics: [],
            extraLines: [],
            statusLine: statusLine)
    }

    static func render(
        cards: [CLICardModel],
        failures: [CLICardFailure],
        terminalWidth: Int,
        useColor: Bool,
        enhanced: Bool = false) -> String
    {
        guard !cards.isEmpty else {
            return self.renderFailuresOnly(failures, useColor: useColor)
        }

        let columns = Self.columnCount(terminalWidth: terminalWidth)
        let width = Self.cardWidth(terminalWidth: terminalWidth, columns: columns)
        var chunks: [String] = []

        for rowStart in stride(from: 0, to: cards.count, by: columns) {
            let rowCards = Array(cards[rowStart..<min(rowStart + columns, cards.count)])
            let rendered = rowCards.map { Self.renderCard($0, width: width, useColor: useColor, enhanced: enhanced) }
            let rowHeight = rendered.map(\.count).max() ?? 0
            for lineIndex in 0..<rowHeight {
                let parts = rendered.map { lines -> String in
                    if lineIndex < lines.count - 1 {
                        return lines[lineIndex]
                    }
                    if lineIndex == rowHeight - 1, let bottom = lines.last {
                        return bottom
                    }
                    return Self.emptyCardLine(width: width, useColor: useColor, enhanced: enhanced)
                }
                chunks.append(parts.joined(separator: String(repeating: " ", count: Self.cardGap)))
            }
            if rowStart + columns < cards.count {
                chunks.append("")
            }
        }

        if !failures.isEmpty {
            if !chunks.isEmpty {
                chunks.append("")
            }
            chunks.append(Self.renderFailureFooter(failures: failures, useColor: useColor))
        }

        return chunks.joined(separator: "\n")
    }

    static func renderCard(_ card: CLICardModel, width: Int, useColor: Bool, enhanced: Bool = false) -> [String] {
        let innerWidth = max(12, width - 4)
        var lines: [String] = []
        lines.append(Self.boxLine(kind: .top, innerWidth: innerWidth, useColor: useColor, enhanced: enhanced))
        lines.append(Self.headerLine(card: card, innerWidth: innerWidth, useColor: useColor, enhanced: enhanced))

        if let account = card.accountLine?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty {
            let active = card.isActive ? " [active]" : ""
            let labelWidth = max(1, innerWidth - 2 - active.count)
            let accountText = "@ \(Self.truncatePlain(account, width: labelWidth))\(active)"
            lines.append(Self.contentLine(
                accountText,
                innerWidth: innerWidth,
                useColor: useColor,
                enhanced: enhanced,
                style: .subtle))
        }

        lines.append(Self.separatorLine(innerWidth: innerWidth, useColor: useColor, enhanced: enhanced))

        if let problem = card.accountProblem, !problem.isEmpty {
            for problemLine in Self.wrapPlainText(problem, width: innerWidth) {
                lines.append(Self.contentLine(
                    problemLine,
                    innerWidth: innerWidth,
                    useColor: useColor,
                    enhanced: enhanced))
            }
        }

        for infoLine in card.infoLines {
            lines.append(Self.detailLine(
                infoLine,
                innerWidth: innerWidth,
                useColor: useColor,
                enhanced: enhanced))
        }

        if !card.metrics.isEmpty, !card.infoLines.isEmpty {
            lines.append(Self.contentLine("", innerWidth: innerWidth, useColor: useColor, enhanced: enhanced))
        }

        for (index, metric) in card.metrics.enumerated() {
            if index > 0 {
                lines.append(Self.contentLine("", innerWidth: innerWidth, useColor: useColor, enhanced: enhanced))
            }
            lines.append(Self.metricLabelLine(
                metric: metric,
                innerWidth: innerWidth,
                useColor: useColor,
                enhanced: enhanced))
            lines.append(Self.metricBarLine(
                metric: metric,
                innerWidth: innerWidth,
                useColor: useColor,
                enhanced: enhanced))
            if let resetText = metric.resetText {
                lines.append(Self.contentLine(
                    resetText,
                    innerWidth: innerWidth,
                    useColor: useColor,
                    enhanced: enhanced,
                    style: .subtle))
            }
            if let detailText = metric.detailText {
                lines.append(Self.contentLine(
                    detailText,
                    innerWidth: innerWidth,
                    useColor: useColor,
                    enhanced: enhanced,
                    style: .subtle))
            }
        }

        for extraLine in card.extraLines {
            lines.append(Self.detailLine(extraLine, innerWidth: innerWidth, useColor: useColor, enhanced: enhanced))
        }

        if let statusLine = card.statusLine {
            lines.append(Self.contentLine(statusLine, innerWidth: innerWidth, useColor: useColor, enhanced: enhanced))
        }

        lines.append(Self.boxLine(kind: .bottom, innerWidth: innerWidth, useColor: useColor, enhanced: enhanced))
        return lines
    }

    private enum BoxLineKind {
        case top
        case bottom
    }

    private enum ContentStyle: Equatable {
        case normal
        case subtle
        case border
    }

    private static func boxLine(kind: BoxLineKind, innerWidth: Int, useColor: Bool, enhanced: Bool) -> String {
        let chars = switch kind {
        case .top: ("╭", "╮")
        case .bottom: ("╰", "╯")
        }
        let line = chars.0 + String(repeating: "─", count: innerWidth + 2) + chars.1
        return Self.styleBorder(line, useColor: useColor, enhanced: enhanced)
    }

    private static func headerLine(card: CLICardModel, innerWidth: Int, useColor: Bool, enhanced: Bool) -> String {
        let title: String
        let badge: String
        if useColor, enhanced {
            title = CLIRenderer.colorizeEnhancedAccentBold(card.title)
            badge = CLIRenderer.colorizeEnhancedBadge(card.sourceLabel)
        } else if useColor {
            title = CLIRenderer.colorizeAccentBold(card.title)
            badge = CLIRenderer.colorizeCardBadge(card.sourceLabel)
        } else {
            title = card.title
            badge = "[\(card.sourceLabel)]"
        }
        let left = "\(title) \(badge)"
        let leftVisible = Self.visibleLength(left)
        let rawPlanText = card.planBadge.map { "PLAN \($0)" } ?? ""
        let maxPlanWidth = max(0, innerWidth - leftVisible - 1)
        let planText = maxPlanWidth >= 8 ? Self.truncatePlain(rawPlanText, width: maxPlanWidth) : ""
        let planVisible = Self.visibleLength(planText)
        let gap = max(1, innerWidth - leftVisible - planVisible)
        let plan = Self.planPill(text: planText, useColor: useColor, enhanced: enhanced)
        let content = left + String(repeating: " ", count: gap) + plan
        return Self.sideBorder(content, innerWidth: innerWidth, useColor: useColor, enhanced: enhanced)
    }

    private static func planPill(text: String, useColor: Bool, enhanced: Bool) -> String {
        guard !text.isEmpty else { return "" }
        let pieces = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else {
            return useColor ? CLIRenderer.colorizeCardPlanBox(text) : text
        }
        if useColor, enhanced {
            return CLIRenderer.colorizeEnhancedPlanLabel(pieces[0])
                + " "
                + CLIRenderer.colorizeEnhancedPlanValue(pieces[1])
        }
        if useColor {
            return CLIRenderer.colorizeCardPlanBox(pieces[0])
                + " "
                + CLIRenderer.colorizeWarning(pieces[1])
        }
        return text
    }

    private static func separatorLine(innerWidth: Int, useColor: Bool, enhanced: Bool) -> String {
        self.sideBorder(
            String(repeating: "─", count: innerWidth),
            innerWidth: innerWidth,
            useColor: useColor,
            enhanced: enhanced,
            contentStyle: .border)
    }

    private static func metricLabelLine(
        metric: CLICardMetric,
        innerWidth: Int,
        useColor: Bool,
        enhanced: Bool) -> String
    {
        let percentText = UsageFormatter.usageLine(
            remaining: metric.remainingPercent,
            used: 100 - metric.remainingPercent,
            showUsed: false)
        let coloredPercent: String = if useColor, enhanced {
            CLIRenderer.colorizeEnhancedRemainingPercent(percentText, remainingPercent: metric.remainingPercent)
        } else {
            CLIRenderer.colorizeCardPercent(
                percentText,
                remainingPercent: metric.remainingPercent,
                useColor: useColor)
        }
        let label: String = if useColor, enhanced {
            CLIRenderer.colorizeEnhancedReadable(metric.label)
        } else if useColor {
            CLIRenderer.colorizeReadable(metric.label)
        } else {
            metric.label
        }
        let gap = max(1, innerWidth - Self.visibleLength(label) - Self.visibleLength(coloredPercent))
        let content = label + String(repeating: " ", count: gap) + coloredPercent
        return Self.sideBorder(content, innerWidth: innerWidth, useColor: useColor, enhanced: enhanced)
    }

    private static func metricBarLine(
        metric: CLICardMetric,
        innerWidth: Int,
        useColor: Bool,
        enhanced: Bool) -> String
    {
        let barWidth = max(4, innerWidth - 4)
        let bar: String = if useColor, enhanced {
            CLIRenderer.gradientRemainingTrackBar(remainingPercent: metric.remainingPercent, width: barWidth)
        } else {
            CLIRenderer.cardBlockBar(
                remainingPercent: metric.remainingPercent,
                width: barWidth,
                useColor: useColor)
        }
        return Self.sideBorder("[ \(bar) ]", innerWidth: innerWidth, useColor: useColor, enhanced: enhanced)
    }

    private static func detailLine(_ content: String, innerWidth: Int, useColor: Bool, enhanced: Bool) -> String {
        let normalized = Self.normalizeGlyphs(content)
        let plain = TextParsing.stripANSICodes(normalized)
        let parts = plain.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return Self.contentLine(normalized, innerWidth: innerWidth, useColor: useColor, enhanced: enhanced)
        }

        let rawLabel = parts[0].trimmingCharacters(in: .whitespacesAndNewlines) + ":"
        let rawValue = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let label: String = if useColor, enhanced {
            CLIRenderer.colorizeEnhancedReadable(rawLabel)
        } else if useColor {
            CLIRenderer.colorizeReadable(rawLabel)
        } else {
            rawLabel
        }
        let value: String = if useColor, enhanced {
            CLIRenderer.colorizeEnhancedGood(rawValue)
        } else if useColor {
            CLIRenderer.colorizeAccent(rawValue)
        } else {
            rawValue
        }
        let gap = max(1, innerWidth - Self.visibleLength(label) - Self.visibleLength(value))
        let line = label + String(repeating: " ", count: gap) + value
        return Self.sideBorder(line, innerWidth: innerWidth, useColor: useColor, enhanced: enhanced)
    }

    private static func contentLine(
        _ content: String,
        innerWidth: Int,
        useColor: Bool,
        enhanced: Bool,
        style: ContentStyle = .normal) -> String
    {
        let normalized = Self.normalizeGlyphs(content)
        let stripped = TextParsing.stripANSICodes(normalized)
        let clipped = stripped.count <= innerWidth
            ? normalized
            : (innerWidth <= 1 ? String(stripped.prefix(innerWidth)) : String(stripped.prefix(innerWidth - 1)) + "…")
        let display: String = if style == .subtle, useColor, enhanced {
            CLIRenderer.colorizeEnhancedSubtle(TextParsing.stripANSICodes(clipped))
        } else if style == .subtle, useColor {
            CLIRenderer.colorizeSubtle(TextParsing.stripANSICodes(clipped))
        } else {
            clipped
        }
        return Self.sideBorder(display, innerWidth: innerWidth, useColor: useColor, enhanced: enhanced)
    }

    private static func sideBorder(
        _ content: String,
        innerWidth: Int,
        useColor: Bool,
        enhanced: Bool,
        contentStyle: ContentStyle = .normal) -> String
    {
        let fitted = Self.fitContent(content, width: innerWidth)
        let padding = max(0, innerWidth - Self.visibleLength(fitted))
        let padded = fitted + String(repeating: " ", count: padding)
        let visible = "│ \(padded) │"
        guard useColor else { return visible }
        let left = Self.styleBorder("│ ", useColor: useColor, enhanced: enhanced)
        let right = Self.styleBorder(" │", useColor: useColor, enhanced: enhanced)
        let styledContent: String = if contentStyle == .border {
            Self.styleBorder(padded, useColor: useColor, enhanced: enhanced)
        } else {
            padded
        }
        return left + styledContent + right
    }

    private static func styleBorder(_ text: String, useColor: Bool, enhanced: Bool) -> String {
        guard useColor else { return text }
        if enhanced {
            return CLIRenderer.colorizeEnhancedBorder(text)
        }
        return CLIRenderer.colorizeCardBorder(text)
    }

    private static func emptyCardLine(width: Int, useColor: Bool, enhanced: Bool) -> String {
        let innerWidth = max(12, width - 4)
        return Self.sideBorder("", innerWidth: innerWidth, useColor: useColor, enhanced: enhanced)
    }

    private static func visibleLength(_ text: String) -> Int {
        TextParsing.stripANSICodes(self.normalizeGlyphs(text)).count
    }

    private static func truncatePlain(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }
        guard text.count > width else { return text }
        if width <= 1 { return String(text.prefix(width)) }
        return String(text.prefix(width - 1)) + "…"
    }

    private static func wrapPlainText(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [] }
        var lines: [String] = []
        var line = ""
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if word.count > width {
                if !line.isEmpty {
                    lines.append(line)
                    line = ""
                }
                var remainder = word[...]
                while remainder.count > width {
                    let end = remainder.index(remainder.startIndex, offsetBy: width)
                    lines.append(String(remainder[..<end]))
                    remainder = remainder[end...]
                }
                line = String(remainder)
            } else if line.isEmpty {
                line = word
            } else if line.count + 1 + word.count <= width {
                line += " " + word
            } else {
                lines.append(line)
                line = word
            }
        }
        if !line.isEmpty {
            lines.append(line)
        }
        return lines
    }

    private static func fitContent(_ text: String, width: Int) -> String {
        guard self.visibleLength(text) > width else { return text }
        return self.truncatePlain(TextParsing.stripANSICodes(text), width: width)
    }

    private static func normalizeGlyphs(_ text: String) -> String {
        text
            .replacingOccurrences(of: "👤", with: "@")
            .replacingOccurrences(of: "⏳ Resets in ", with: "Reset in ")
            .replacingOccurrences(of: "⏳ Resets ", with: "Reset ")
            .replacingOccurrences(of: "⏳ ", with: "Reset ")
    }

    static func renderFailureFooter(failures: [CLICardFailure], useColor: Bool) -> String {
        var lines = ["Failed providers:"]
        for failure in failures {
            let name = ProviderDescriptorRegistry.descriptor(for: failure.provider).metadata.displayName
            if let account = failure.accountLabel, !account.isEmpty {
                lines.append("  - \(name) (\(account)): \(failure.message)")
            } else {
                lines.append("  - \(name): \(failure.message)")
            }
        }
        let text = lines.joined(separator: "\n")
        guard useColor else { return text }
        return CLIRenderer.colorizeError(text)
    }

    static func renderFailuresOnly(_ failures: [CLICardFailure], useColor: Bool) -> String {
        guard !failures.isEmpty else { return "" }
        return self.renderFailureFooter(failures: failures, useColor: useColor)
    }

    private static func normalizedSourceLabel(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "auto" }
        if trimmed.contains("oauth") { return "oauth" }
        if trimmed.contains("web") || trimmed.contains("openai-web") { return "web" }
        if trimmed.contains("api") { return "api" }
        if trimmed.contains("cli") { return "cli" }
        return trimmed
    }
}
