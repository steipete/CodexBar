import CodexBarCore
import Foundation
import SwiftUI

extension UsageMenuCardView.Model {
    static func miniMaxSections(input: Input) -> [MiniMaxSection]? {
        guard input.provider == .minimax,
              let models = input.snapshot?.minimaxUsage?.models,
              !models.isEmpty
        else {
            return nil
        }
        let hasWeeklyDetail = models.contains { $0.weeklyTotal != nil || $0.weeklyRemaining != nil }
        guard models.count > 1 || hasWeeklyDetail else {
            return nil
        }

        let fiveHour = models.filter { if case .fiveHour = $0.window { return true }; return false }
        let daily = models.filter { if case .daily = $0.window { return true }; return false }
        let weeklyOnly = models.filter { if case .weekly = $0.window { return true }; return false }
        let other = models.filter { if case .other = $0.window { return true }; return false }

        var sections: [MiniMaxSection] = []
        if !fiveHour.isEmpty {
            sections.append(MiniMaxSection(
                title: "5-hour window",
                rows: fiveHour.map { Self.miniMaxRow(model: $0, input: input) }))
        }
        if !daily.isEmpty {
            sections.append(MiniMaxSection(
                title: "Daily quota",
                rows: daily.map { Self.miniMaxRow(model: $0, input: input) }))
        }
        if !weeklyOnly.isEmpty {
            sections.append(MiniMaxSection(
                title: "Weekly quota",
                rows: weeklyOnly.map { Self.miniMaxRow(model: $0, input: input) }))
        }
        if !other.isEmpty {
            sections.append(MiniMaxSection(
                title: "Other windows",
                rows: other.map { Self.miniMaxRow(model: $0, input: input) }))
        }
        return sections.isEmpty ? nil : sections
    }

    static func miniMaxRow(model: MiniMaxModelUsage, input: Input) -> MiniMaxRow {
        let percentStyle: PercentStyle = input.usageBarsShowUsed ? .used : .left
        let used = model.usedPercent
        let barPercent = used.map { percentStyle == .used ? $0 : (100 - $0) }
        let resetText: String? = if let at = model.resetsAt {
            UsageFormatter.resetLine(
                for: RateWindow(
                    usedPercent: used ?? 0,
                    windowMinutes: model.windowMinutes,
                    resetsAt: at,
                    resetDescription: nil),
                style: input.resetTimeDisplayStyle,
                now: input.now)
        } else {
            nil
        }
        let detailText = Self.miniMaxDetailLine(model: model)
        let secondaryLine = Self.miniMaxWeeklySecondaryLine(model: model, input: input)
        return MiniMaxRow(
            id: model.identifier,
            title: model.displayName,
            percent: barPercent.map { Self.clamped($0) },
            percentStyle: percentStyle,
            resetText: resetText,
            detailText: detailText,
            secondaryLine: secondaryLine)
    }

    static func miniMaxDetailLine(model: MiniMaxModelUsage) -> String? {
        guard let total = model.availablePrompts else { return nil }

        // 与 MiniMaxUsageFetcher 一致：仅当同时有 total+remaining（或解析出的 current）时才推导已用量；
        // remaining 缺省时不得假定为 0，否则会显示成「用尽」且与省略的 current_interval_usage_count 矛盾。
        let used: Int? = if let current = model.currentPrompts {
            current
        } else if let remaining = model.remainingPrompts {
            max(0, total - remaining)
        } else {
            nil
        }

        let remaining = model.remainingPrompts
        // 区间额度占位 0/0 时不展示误导性用量（与周限 0/0 同类问题）。
        if total == 0, (used ?? 0) == 0, remaining == nil || remaining == 0 {
            return nil
        }

        let totalStr = UsageFormatter.tokenCountString(total)
        guard let used else {
            return "—/\(totalStr)"
        }

        let usedStr = UsageFormatter.tokenCountString(used)
        if let remaining {
            let remStr = UsageFormatter.tokenCountString(remaining)
            return "\(usedStr)/\(totalStr) (\(remStr) remaining)"
        }
        return "\(usedStr)/\(totalStr)"
    }

    static func miniMaxWeeklySecondaryLine(model: MiniMaxModelUsage, input: Input) -> String? {
        guard model.weeklyTotal != nil || model.weeklyRemaining != nil else { return nil }
        // 与解析层一致：任一侧为 0、另一侧缺省时按 0 计；全零即无周限，不展示误导性周限行。
        if (model.weeklyTotal ?? 0) == 0, (model.weeklyRemaining ?? 0) == 0 { return nil }
        let total = model.weeklyTotal
        let used = model.weeklyUsed
        let remaining = model.weeklyRemaining
        let usedStr = used.map { UsageFormatter.tokenCountString($0) } ?? "—"
        let totalStr = total.map { UsageFormatter.tokenCountString($0) } ?? "—"
        let pctStr = if let p = model.weeklyUsedPercent {
            String(format: "%.1f%%", p)
        } else {
            "—"
        }
        let weeklyReset: String? = if let at = model.weeklyResetsAt {
            UsageFormatter.resetLine(
                for: RateWindow(
                    usedPercent: model.weeklyUsedPercent ?? 0,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: at,
                    resetDescription: nil),
                style: input.resetTimeDisplayStyle,
                now: input.now)
        } else {
            nil
        }
        let remStr = remaining.map { UsageFormatter.tokenCountString($0) }
        var line = "↳ Weekly \(usedStr)/\(totalStr) (\(pctStr) used)"
        if let remStr {
            line += " · \(remStr) remaining"
        }
        if let weeklyReset {
            line += " · \(weeklyReset)"
        }
        return line
    }
}
