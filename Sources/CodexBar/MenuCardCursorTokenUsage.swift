import CodexBarCore
import SwiftUI

extension UsageMenuCardView.Model {
    static func tokenUsageSection(input: Input) -> TokenUsageSection? {
        if input.provider == .cursor,
           let rangeSummaries = input.snapshot?.cursorRangeSummaries,
           let rangeSummary = rangeSummaries.first(where: { $0.rangeKind == input.cursorUsageRangeKind })
           ?? rangeSummaries.first
        {
            let sessionLine = "\(rangeSummary.rangeKind.label): "
                + "\(UsageFormatter.tokenCountString(rangeSummary.tokens)) tokens"
            return TokenUsageSection(
                title: "Cursor usage",
                sessionLine: sessionLine,
                monthLine: "\(rangeSummary.requests) requests",
                cursorRangeKinds: rangeSummaries.map(\.rangeKind),
                selectedCursorRangeKind: rangeSummary.rangeKind,
                selectCursorRange: input.selectCursorUsageRange,
                cursorRequestDetails: rangeSummary.recentRequests,
                hintLine: nil,
                errorLine: nil,
                errorCopyText: nil)
        }

        guard input.provider == .codex || input.provider == .claude || input.provider == .vertexai,
              input.tokenCostUsageEnabled,
              let snapshot = input.tokenSnapshot
        else {
            return nil
        }

        let sessionCost = snapshot.sessionCostUSD.map { UsageFormatter.usdString($0) } ?? "—"
        let sessionTokens = snapshot.sessionTokens.map { UsageFormatter.tokenCountString($0) }
        let sessionLine = if let sessionTokens {
            "Today: \(sessionCost) · \(sessionTokens) tokens"
        } else {
            "Today: \(sessionCost)"
        }
        let monthCost = snapshot.last30DaysCostUSD.map { UsageFormatter.usdString($0) } ?? "—"
        let fallbackTokens = snapshot.daily.compactMap(\.totalTokens).reduce(0, +)
        let monthTokensValue = snapshot.last30DaysTokens ?? (fallbackTokens > 0 ? fallbackTokens : nil)
        let monthLine = if let monthTokens = monthTokensValue.map({ UsageFormatter.tokenCountString($0) }) {
            "Last 30 days: \(monthCost) · \(monthTokens) tokens"
        } else {
            "Last 30 days: \(monthCost)"
        }
        let error = (input.tokenError?.isEmpty ?? true) ? nil : input.tokenError
        return TokenUsageSection(
            title: "Cost",
            sessionLine: sessionLine,
            monthLine: monthLine,
            cursorRangeKinds: [],
            selectedCursorRangeKind: nil,
            selectCursorRange: nil,
            cursorRequestDetails: [],
            hintLine: nil,
            errorLine: error,
            errorCopyText: error)
    }
}

struct CursorTokenUsageHeader: View {
    let tokenUsage: UsageMenuCardView.Model.TokenUsageSection

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(self.tokenUsage.title)
                .font(.body)
                .fontWeight(.medium)
            Spacer(minLength: 8)
            if !self.tokenUsage.cursorRangeKinds.isEmpty,
               let selected = self.tokenUsage.selectedCursorRangeKind,
               let select = self.tokenUsage.selectCursorRange
            {
                Picker(
                    "Cursor usage range",
                    selection: Binding(get: { selected }, set: { select($0) }))
                {
                    ForEach(self.tokenUsage.cursorRangeKinds, id: \.self) { range in
                        Text(range.label).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
            }
        }
    }
}

struct CursorRequestDetailsList: View {
    let requests: [CursorRecentRequest]

    var body: some View {
        if !self.requests.isEmpty {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(self.requests.prefix(30).enumerated()), id: \.offset) { _, request in
                        let normalized = CursorModelNormalizer.normalize(request.model)
                        let estimate = CursorRequestCostEstimator.estimate(for: request)
                        HStack(alignment: .firstTextBaseline) {
                            Text(UsageFormatter.cursorCompactModelLabel(normalized))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(UsageFormatter.cursorRequestCountLabel(requests: request.requests))
                                if let estimateText = UsageFormatter.cursorEstimateText(estimate) {
                                    Text(estimateText)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.caption)
                        if let requestCostDetail = UsageFormatter
                            .cursorRequestCostDetail(requestCost: request.requestCost)
                        {
                            Text(requestCostDetail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 120)
        }
    }
}
