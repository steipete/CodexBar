import CodexBarCore
import Foundation

struct CLICardsBriefRow: Sendable, Equatable {
    let provider: UsageProvider
    let providerName: String
    let sourceLabel: String
    let planBadge: String?
    let accountLabel: String?
    let isActive: Bool
    let accountProblem: String?
    let metricLabel: String?
    let usedPercent: Double?
    let resetLabel: String?
    let resetAt: Date?
}

private struct CLICardsBriefColumns {
    let provider: Int
    let usage: Int
    let reset: Int
}

enum CLICardsBriefRenderer {
    private static let warningUsedThreshold = 85.0
    private static let tableBorderOverhead = 10
    private static let providerColumnMin = 20
    private static let providerColumnFloor = 8
    private static let providerColumnMax = 34
    private static let usageColumnMin = 22
    private static let usageColumnFloor = 9
    private static let usageColumnWidth = 28
    private static let usageBarMaxWidth = 22
    private static let resetColumnMin = 8
    private static let resetColumnFloor = 5
    private static let resetColumnMax = 10

    static func makeRows(cards: [CLICardModel]) -> [CLICardsBriefRow] {
        cards.map { card in
            let metric = card.metrics.first
            let usedPercent = metric.map { max(0, min(100, 100 - $0.remainingPercent)) }
            let resetLabel = Self.briefResetLabel(metric?.resetText)
            return CLICardsBriefRow(
                provider: card.provider,
                providerName: card.title,
                sourceLabel: card.sourceLabel,
                planBadge: card.planBadge,
                accountLabel: card.accountLine,
                isActive: card.isActive,
                accountProblem: card.accountProblem,
                metricLabel: metric?.label,
                usedPercent: usedPercent,
                resetLabel: resetLabel,
                resetAt: metric?.resetAt)
        }
    }

    static func render(
        rows: [CLICardsBriefRow],
        failures: [CLICardFailure],
        terminalWidth: Int,
        useColor: Bool,
        enhanced: Bool = false,
        now: Date = Date()) -> String
    {
        guard !rows.isEmpty else {
            return CLICardsRenderer.renderFailuresOnly(failures, useColor: useColor)
        }

        var lines: [String] = []
        lines.append(Self.titleLine(now: now, terminalWidth: terminalWidth, useColor: useColor, enhanced: enhanced))
        lines.append(contentsOf: Self.summaryLines(
            rows: rows,
            now: now,
            terminalWidth: terminalWidth,
            useColor: useColor,
            enhanced: enhanced))
        lines.append("")
        lines.append(contentsOf: Self.tableLines(
            rows: rows,
            terminalWidth: terminalWidth,
            useColor: useColor,
            enhanced: enhanced))

        let warningLines = Self.warningLines(rows: rows, terminalWidth: terminalWidth, useColor: useColor)
        if !warningLines.isEmpty {
            lines.append("")
            lines.append(contentsOf: warningLines)
        }

        if !failures.isEmpty {
            lines.append("")
            lines.append(CLICardsRenderer.renderFailureFooter(failures: failures, useColor: useColor))
        }

        return lines.joined(separator: "\n")
    }

    private static func titleLine(now: Date, terminalWidth: Int, useColor: Bool, enhanced: Bool) -> String {
        let left: String = if useColor, enhanced {
            CLIRenderer.colorizeEnhancedAccentBold("codexbar • AI Usage & Limits")
        } else if useColor {
            CLIRenderer.colorizeAccentBold("codexbar • AI Usage & Limits")
        } else {
            "codexbar • AI Usage & Limits"
        }
        let timestamp = Self.timestampString(now: now)
        guard Self.visibleLength(left) + timestamp.count + 1 <= terminalWidth else {
            if Self.visibleLength(left) <= terminalWidth { return left }
            return Self.truncatePlain(TextParsing.stripANSICodes(left), width: terminalWidth)
        }
        let gap = max(1, terminalWidth - Self.visibleLength(left) - timestamp.count)
        let right: String = if useColor, enhanced {
            CLIRenderer.colorizeEnhancedReadableMuted(timestamp)
        } else if useColor {
            CLIRenderer.colorizeSubtle(timestamp)
        } else {
            timestamp
        }
        return left + String(repeating: " ", count: gap) + right
    }

    private static func summaryLines(
        rows: [CLICardsBriefRow],
        now: Date,
        terminalWidth: Int,
        useColor: Bool,
        enhanced: Bool) -> [String]
    {
        var parts: [String] = []
        if let nextReset = Self.nextResetSummary(rows: rows, now: now) {
            parts.append("Next reset: \(nextReset)")
        }
        let text = parts.joined(separator: " • ")
        guard !text.isEmpty else { return [] }
        let lines = Self.wrapText(
            text,
            firstPrefix: "",
            continuationPrefix: "  ",
            width: terminalWidth)
        if useColor, enhanced {
            return lines.map(CLIRenderer.colorizeEnhancedReadable)
        }
        if useColor {
            return lines.map(CLIRenderer.colorizeReadable)
        }
        return lines
    }

    private static func providerPlainLabel(_ row: CLICardsBriefRow) -> String {
        if let account = row.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty {
            let active = row.isActive ? " [active]" : ""
            return "\(row.providerName)\(active) · \(account) · \(row.sourceLabel)"
        }
        if let plan = row.planBadge, !plan.isEmpty {
            return "\(row.providerName) · \(row.sourceLabel) · \(plan)"
        }
        return "\(row.providerName) · \(row.sourceLabel)"
    }

    private static func tableLines(
        rows: [CLICardsBriefRow],
        terminalWidth: Int,
        useColor: Bool,
        enhanced: Bool) -> [String]
    {
        let columns = Self.tableColumnWidths(
            rows: rows,
            terminalWidth: terminalWidth)

        let top = Self.tableTop(
            providerWidth: columns.provider,
            usageWidth: columns.usage,
            resetWidth: columns.reset,
            useColor: useColor,
            enhanced: enhanced)
        let header = Self.tableHeaderRow(
            providerWidth: columns.provider,
            usageWidth: columns.usage,
            resetWidth: columns.reset,
            useColor: useColor,
            enhanced: enhanced)
        let divider = Self.tableDivider(
            providerWidth: columns.provider,
            usageWidth: columns.usage,
            resetWidth: columns.reset,
            useColor: useColor,
            enhanced: enhanced)

        var lines = [top, header, divider]
        for row in rows {
            lines.append(Self.dataRow(
                row: row,
                columns: columns,
                useColor: useColor,
                enhanced: enhanced))
        }
        lines.append(Self.tableBottom(
            providerWidth: columns.provider,
            usageWidth: columns.usage,
            resetWidth: columns.reset,
            useColor: useColor,
            enhanced: enhanced))
        return lines
    }

    private static func tableBorderLine(_ line: String, useColor: Bool, enhanced: Bool) -> String {
        guard useColor else { return line }
        if enhanced {
            return CLIRenderer.colorizeEnhancedBorder(line)
        }
        return CLIRenderer.colorizeCardBorder(line)
    }

    private static func tableHeaderRow(
        providerWidth: Int,
        usageWidth: Int,
        resetWidth: Int,
        useColor: Bool,
        enhanced: Bool) -> String
    {
        let provider = Self.styledHeaderLabel("Provider", width: providerWidth, useColor: useColor, enhanced: enhanced)
        let usage = Self.styledHeaderLabel("Usage", width: usageWidth, useColor: useColor, enhanced: enhanced)
        let reset = Self.styledHeaderLabel(
            "Reset",
            width: resetWidth,
            alignRight: true,
            useColor: useColor,
            enhanced: enhanced)
        return "│ \(provider) │ \(usage) │ \(reset) │"
    }

    private static func styledHeaderLabel(
        _ text: String,
        width: Int,
        alignRight: Bool = false,
        useColor: Bool,
        enhanced: Bool) -> String
    {
        let styled: String = if useColor, enhanced {
            CLIRenderer.colorizeEnhancedReadable(text)
        } else if useColor {
            CLIRenderer.colorizeReadable(text)
        } else {
            text
        }
        return Self.pad(styled, width: width, alignRight: alignRight)
    }

    private static func tableTop(
        providerWidth: Int,
        usageWidth: Int,
        resetWidth: Int,
        useColor: Bool,
        enhanced: Bool) -> String
    {
        let line = "┌" + String(repeating: "─", count: providerWidth + 2)
            + "┬" + String(repeating: "─", count: usageWidth + 2)
            + "┬" + String(repeating: "─", count: resetWidth + 2) + "┐"
        return Self.tableBorderLine(line, useColor: useColor, enhanced: enhanced)
    }

    private static func tableBottom(
        providerWidth: Int,
        usageWidth: Int,
        resetWidth: Int,
        useColor: Bool,
        enhanced: Bool) -> String
    {
        let line = "└" + String(repeating: "─", count: providerWidth + 2)
            + "┴" + String(repeating: "─", count: usageWidth + 2)
            + "┴" + String(repeating: "─", count: resetWidth + 2) + "┘"
        return Self.tableBorderLine(line, useColor: useColor, enhanced: enhanced)
    }

    private static func tableDivider(
        providerWidth: Int,
        usageWidth: Int,
        resetWidth: Int,
        useColor: Bool,
        enhanced: Bool) -> String
    {
        let line = "├" + String(repeating: "─", count: providerWidth + 2)
            + "┼" + String(repeating: "─", count: usageWidth + 2)
            + "┼" + String(repeating: "─", count: resetWidth + 2) + "┤"
        return Self.tableBorderLine(line, useColor: useColor, enhanced: enhanced)
    }

    private static func styledProviderCell(
        row: CLICardsBriefRow,
        width: Int,
        useColor: Bool,
        enhanced: Bool) -> String
    {
        if row.isActive, width < row.providerName.count + " [active]".count {
            let fitted = Self.fitCell("[active]", width: width)
            if useColor, enhanced {
                return CLIRenderer.colorizeEnhancedReadable(fitted)
            }
            return useColor ? CLIRenderer.colorizeReadable(fitted) : fitted
        }
        if row.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            let fitted = Self.fitCell(Self.providerPlainLabel(row), width: width)
            if useColor, enhanced {
                return CLIRenderer.colorizeEnhancedReadable(fitted)
            }
            return useColor ? CLIRenderer.colorizeReadable(fitted) : fitted
        }
        guard useColor else {
            return self.plainProviderCell(row: row, width: width)
        }

        let sourceVisibleWidth = row.sourceLabel.count + 2
        let prefixVisibleWidth = row.providerName.count + 1 + sourceVisibleWidth
        let plan: String? = row.planBadge.flatMap { $0.isEmpty ? nil : $0 }
        let planPrefix = " · "
        let planWidth = plan.map { _ in max(0, width - prefixVisibleWidth - planPrefix.count) } ?? 0

        let styled: String = if enhanced {
            CLIRenderer.colorizeEnhancedAccentBold(row.providerName)
                + " "
                + CLIRenderer.colorizeEnhancedBadge(row.sourceLabel)
                + Self.styledProviderPlan(
                    plan,
                    prefix: planPrefix,
                    width: planWidth,
                    useColor: useColor,
                    enhanced: enhanced)
        } else {
            CLIRenderer.colorizeReadable(row.providerName)
                + " "
                + CLIRenderer.colorizeCardBadge(row.sourceLabel)
                + Self.styledProviderPlan(
                    plan,
                    prefix: planPrefix,
                    width: planWidth,
                    useColor: useColor,
                    enhanced: enhanced)
        }
        return Self.fitCell(styled, width: width)
    }

    private static func styledProviderPlan(
        _ plan: String?,
        prefix: String,
        width: Int,
        useColor: Bool,
        enhanced: Bool) -> String
    {
        guard let plan, width > 0 else { return "" }
        let text = prefix + Self.truncatePlain(plan, width: width)
        if useColor, enhanced {
            return CLIRenderer.colorizeEnhancedReadableMuted(text)
        }
        if useColor {
            return CLIRenderer.colorizeReadableMuted(text)
        }
        return text
    }

    private static func plainProviderCell(row: CLICardsBriefRow, width: Int) -> String {
        if row.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return self.fitCell(self.providerPlainLabel(row), width: width)
        }
        guard
            let plan = row.planBadge,
            !plan.isEmpty
        else {
            return self.fitCell(self.providerPlainLabel(row), width: width)
        }

        let prefix = "\(row.providerName) · \(row.sourceLabel) · "
        let planWidth = max(0, width - prefix.count)
        if planWidth > 0 {
            return Self.pad(prefix + Self.truncatePlain(plan, width: planWidth), width: width)
        }
        return Self.fitCell("\(row.providerName) · \(row.sourceLabel)", width: width)
    }

    private static func styledResetCell(_ text: String, width: Int, useColor: Bool, enhanced: Bool) -> String {
        let styled: String = if useColor, enhanced {
            CLIRenderer.colorizeEnhancedReadableMuted(text)
        } else if useColor {
            CLIRenderer.colorizeReadableMuted(text)
        } else {
            text
        }
        return Self.fitCell(styled, width: width, alignRight: true)
    }

    private static func dataRow(
        row: CLICardsBriefRow,
        columns: CLICardsBriefColumns,
        useColor: Bool,
        enhanced: Bool) -> String
    {
        let provider = Self.styledProviderCell(
            row: row,
            width: columns.provider,
            useColor: useColor,
            enhanced: enhanced)
        let usage: String
        if let problem = row.accountProblem, !problem.isEmpty {
            let fitted = Self.fitCell(problem, width: columns.usage)
            if useColor, enhanced {
                usage = CLIRenderer.colorizeEnhancedReadable(fitted)
            } else if useColor {
                usage = CLIRenderer.colorizeReadable(fitted)
            } else {
                usage = fitted
            }
        } else if let used = row.usedPercent {
            let percent = String(format: "%.0f%%", used.rounded())
            let barWidth = max(4, min(Self.usageBarMaxWidth, columns.usage - Self.visibleLength(percent) - 1))
            let bar: String = if useColor, enhanced {
                CLIRenderer.gradientUsedBar(usedPercent: used, width: barWidth)
            } else {
                CLIRenderer.cardUsedBar(usedPercent: used, width: barWidth, useColor: useColor)
            }
            let coloredPercent: String = if useColor, enhanced {
                CLIRenderer.colorizeEnhancedUsedPercent(percent, usedPercent: used)
            } else {
                CLIRenderer.colorizeCardUsedPercent(percent, usedPercent: used, useColor: useColor)
            }
            usage = Self.pad("\(coloredPercent) \(bar)", width: columns.usage)
        } else {
            usage = Self.pad("—", width: columns.usage)
        }
        let reset = Self.styledResetCell(
            row.resetLabel ?? "—",
            width: columns.reset,
            useColor: useColor,
            enhanced: enhanced)
        return "│ \(provider) │ \(usage) │ \(reset) │"
    }

    private static func warningLines(
        rows: [CLICardsBriefRow],
        terminalWidth: Int,
        useColor: Bool) -> [String]
    {
        let warnings = rows.compactMap { row -> String? in
            guard let used = row.usedPercent, used >= Self.warningUsedThreshold else { return nil }
            let label = row.metricLabel ?? "Usage"
            return "\(row.providerName) \(label): \(Int(used.rounded()))% used"
        }
        guard !warnings.isEmpty else { return [] }
        let lines = Self.wrapText(
            warnings.joined(separator: "; "),
            firstPrefix: "⚠ Warnings: ",
            continuationPrefix: "  ",
            width: terminalWidth)
        return useColor ? lines.map(CLIRenderer.colorizeWarning) : lines
    }

    private static func wrapText(
        _ text: String,
        firstPrefix: String,
        continuationPrefix: String,
        width: Int) -> [String]
    {
        let lineWidth = max(16, width)
        var lines: [String] = []
        var line = firstPrefix
        var hasContent = false
        for word in text.split(separator: " ").map(String.init) {
            let separator = hasContent ? " " : ""
            if line.count + separator.count + word.count <= lineWidth {
                line += separator + word
                hasContent = true
                continue
            }
            if hasContent {
                lines.append(line)
            } else if !line.isEmpty {
                lines.append(Self.truncatePlain(line, width: lineWidth))
            }
            let available = max(1, lineWidth - continuationPrefix.count)
            line = continuationPrefix + Self.truncatePlain(word, width: available)
            hasContent = true
        }
        if hasContent {
            lines.append(line)
        }
        return lines
    }

    private static func nextResetSummary(rows: [CLICardsBriefRow], now: Date) -> String? {
        guard let (row, label, _) = rows.compactMap({ row -> (CLICardsBriefRow, String, Date)? in
            guard let reset = row.resetLabel, !reset.isEmpty, reset != "—" else { return nil }
            let sortDate = row.resetAt ?? Self.resetSortDate(reset, now: now)
            guard let sortDate else { return nil }
            return (row, reset, sortDate)
        }).min(by: { $0.2 < $1.2 })
        else { return nil }
        let separator = Self.resetDurationMinutes(label) == nil ? " · " : " in "
        return "\(row.providerName)\(separator)\(label)"
    }

    private static func resetSortDate(_ label: String, now: Date) -> Date? {
        guard let minutes = resetDurationMinutes(label) else { return nil }
        return now.addingTimeInterval(TimeInterval(minutes * 60))
    }

    private static func resetDurationMinutes(_ label: String) -> Int? {
        var minutes = 0
        var matched = false
        if let match = label.range(of: #"(\d+)d"#, options: .regularExpression) {
            matched = true
            minutes += (Int(label[match].dropLast()) ?? 0) * 24 * 60
        }
        if let match = label.range(of: #"(\d+)h"#, options: .regularExpression) {
            matched = true
            minutes += (Int(label[match].dropLast()) ?? 0) * 60
        }
        if let match = label.range(of: #"(\d+)m"#, options: .regularExpression) {
            matched = true
            minutes += Int(label[match].dropLast()) ?? 0
        }
        return matched ? minutes : nil
    }

    private static func tableColumnWidths(
        rows: [CLICardsBriefRow],
        terminalWidth: Int) -> CLICardsBriefColumns
    {
        let providerContent = rows.map { Self.providerPlainLabel($0).count }.max() ?? Self.providerColumnMin
        let resetContent = rows.compactMap(\.resetLabel).map(\.count).max() ?? 6

        var providerWidth = min(Self.providerColumnMax, max(Self.providerColumnMin, providerContent))
        var usageWidth = Self.usageColumnWidth
        var resetWidth = min(Self.resetColumnMax, max(Self.resetColumnMin, resetContent))

        while providerWidth + usageWidth + resetWidth + Self.tableBorderOverhead > terminalWidth {
            if usageWidth > Self.usageColumnMin {
                usageWidth -= 1
            } else if providerWidth > Self.providerColumnMin {
                providerWidth -= 1
            } else if resetWidth > Self.resetColumnMin {
                resetWidth -= 1
            } else {
                break
            }
        }

        while providerWidth + usageWidth + resetWidth + Self.tableBorderOverhead > terminalWidth {
            if providerWidth > Self.providerColumnFloor {
                providerWidth -= 1
            } else if usageWidth > Self.usageColumnFloor {
                usageWidth -= 1
            } else if resetWidth > Self.resetColumnFloor {
                resetWidth -= 1
            } else {
                break
            }
        }

        return CLICardsBriefColumns(provider: providerWidth, usage: usageWidth, reset: resetWidth)
    }

    private static func briefResetLabel(_ resetText: String?) -> String? {
        guard var text = resetText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.hasPrefix("⏳ ") {
            text = String(text.dropFirst(2))
        }
        if text.hasPrefix("Resets in ") {
            text = String(text.dropFirst("Resets in ".count))
        } else if text.hasPrefix("Resets ") {
            text = String(text.dropFirst("Resets ".count))
        }
        return text.isEmpty ? nil : text
    }

    private static func timestampString(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return formatter.string(from: now)
    }

    private static func pad(_ text: String, width: Int, alignRight: Bool = false) -> String {
        let visible = Self.visibleLength(text)
        if visible >= width { return text }
        let padding = String(repeating: " ", count: width - visible)
        return alignRight ? padding + text : text + padding
    }

    private static func fitCell(_ text: String, width: Int, alignRight: Bool = false) -> String {
        let visible = Self.visibleLength(text)
        if visible <= width {
            return Self.pad(text, width: width, alignRight: alignRight)
        }
        let plain = TextParsing.stripANSICodes(text)
        let clipped = Self.truncatePlain(plain, width: width)
        return alignRight ? Self.pad(clipped, width: width, alignRight: true) : clipped
    }

    private static func truncatePlain(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }
        if text.count <= width { return text }
        guard width > 1 else { return String(text.prefix(width)) }
        return String(text.prefix(width - 1)) + "…"
    }

    private static func visibleLength(_ text: String) -> Int {
        TextParsing.stripANSICodes(text).count
    }
}
