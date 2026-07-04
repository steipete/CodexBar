import Foundation

extension UsageMenuCardView.Model {
    func heightFingerprint(section: String, additional: [String] = []) -> String {
        let notesFingerprint = MenuCardHeightFingerprint.join(self.usageNotes.map {
            MenuCardHeightFingerprint.field("note", $0)
        })
        return MenuCardHeightFingerprint.join([
            "section=\(section)",
            "provider=\(self.provider.rawValue)",
            "localization=\(codexBarLocalizationSignature())",
            MenuCardHeightFingerprint.field("name", self.providerName),
            MenuCardHeightFingerprint.field("email", self.email),
            MenuCardHeightFingerprint.field("subtitle", self.subtitleText),
            "subtitleStyle=\(self.subtitleStyle.heightFingerprint)",
            MenuCardHeightFingerprint.field("plan", self.planText),
            MenuCardHeightFingerprint.field("placeholder", self.placeholder),
            MenuCardHeightFingerprint.field("credits", self.creditsText),
            "creditsRemaining=\(self.creditsRemaining.map(String.init(describing:)) ?? "nil")",
            MenuCardHeightFingerprint.field("creditsHint", self.creditsHintText),
            MenuCardHeightFingerprint.field("creditsCopy", self.creditsHintCopyText),
            "codexResetCredits=\(self.codexResetCredits?.heightFingerprint ?? "")",
            "metrics=\(MenuCardHeightFingerprint.join(self.metrics.map(\.heightFingerprint)))",
            "notes=\(notesFingerprint)",
            "dashboard=\(self.inlineUsageDashboard?.heightFingerprint ?? "")",
            "providerCost=\(self.providerCost?.heightFingerprint ?? "")",
            "tokenUsage=\(self.tokenUsage?.heightFingerprint ?? "")",
            "openaiAPI=\(self.openAIAPIUsage == nil ? "0" : "1")",
        ] + additional)
    }

    static func heightFingerprintField(_ name: String, _ value: String?) -> String {
        MenuCardHeightFingerprint.field(name, value)
    }
}

private enum MenuCardHeightFingerprint {
    private static let hashSalt = UUID()

    static func join(_ values: [String]) -> String {
        values.map { "\($0.count):\($0)" }.joined(separator: "|")
    }

    static func field(_ name: String, _ value: String?) -> String {
        guard let value else {
            return "\(name)=nil"
        }
        return "\(name)=\(Self.stringShape(value))"
    }

    private static func stringShape(_ value: String) -> String {
        var hasher = Hasher()
        hasher.combine(Self.hashSalt)
        hasher.combine(value)
        let digest = String(UInt(bitPattern: hasher.finalize()), radix: 16)
        return "chars:\(value.count),utf8:\(value.utf8.count),lines:\(Self.lineCount(value)),hash:\(digest)"
    }

    private static func lineCount(_ value: String) -> Int {
        guard !value.isEmpty else { return 0 }
        return value.utf8.reduce(1) { count, byte in
            byte == 10 ? count + 1 : count
        }
    }
}

extension UsageMenuCardView.Model.SubtitleStyle {
    fileprivate var heightFingerprint: String {
        switch self {
        case .info: "info"
        case .loading: "loading"
        case .error: "error"
        }
    }
}

extension UsageMenuCardView.Model.Metric {
    fileprivate var heightFingerprint: String {
        MenuCardHeightFingerprint.join([
            self.id,
            MenuCardHeightFingerprint.field("title", self.title),
            "percent=\(Int(self.percent.rounded()))",
            "percentStyle=\(self.percentStyle.rawValue)",
            MenuCardHeightFingerprint.field("status", self.statusText),
            MenuCardHeightFingerprint.field("reset", self.resetText),
            MenuCardHeightFingerprint.field("detail", self.detailText),
            MenuCardHeightFingerprint.field("detailLeft", self.detailLeftText),
            MenuCardHeightFingerprint.field("detailRight", self.detailRightText),
            self.pacePercent == nil ? "pace=0" : "pace=1",
            self.paceOnTop ? "paceTop=1" : "paceTop=0",
            self.cardStyle ? "card=1" : "card=0",
            "markers=\(self.warningMarkerPercents.count)",
        ])
    }
}

extension UsageMenuCardView.Model.ProviderCostSection {
    fileprivate var heightFingerprint: String {
        MenuCardHeightFingerprint.join([
            MenuCardHeightFingerprint.field("title", self.title),
            MenuCardHeightFingerprint.field("spend", self.spendLine),
            MenuCardHeightFingerprint.field("percentLine", self.percentLine),
            MenuCardHeightFingerprint.field("personalSpend", self.personalSpendLine),
            self.percentUsed == nil ? "percent=0" : "percent=1",
        ])
    }
}

extension UsageMenuCardView.Model.TokenUsageSection {
    fileprivate var heightFingerprint: String {
        MenuCardHeightFingerprint.join([
            MenuCardHeightFingerprint.field("session", self.sessionLine),
            MenuCardHeightFingerprint.field("month", self.monthLine),
            MenuCardHeightFingerprint.field("comparisons", self.comparisonLines.joined(separator: "|")),
            MenuCardHeightFingerprint.field("hint", self.hintLine),
            MenuCardHeightFingerprint.field("error", self.errorLine),
            MenuCardHeightFingerprint.field("errorCopy", self.errorCopyText),
        ])
    }
}

extension CodexResetCreditsPresentation {
    fileprivate var heightFingerprint: String {
        MenuCardHeightFingerprint.join([
            MenuCardHeightFingerprint.field("text", self.text),
            MenuCardHeightFingerprint.field("expirySummary", self.expirySummaryText),
        ])
    }
}

extension InlineUsageDashboardModel {
    fileprivate var heightFingerprint: String {
        MenuCardHeightFingerprint.join([
            MenuCardHeightFingerprint.field("accessibility", self.accessibilityLabel),
            self.valueStyle.heightFingerprint,
            MenuCardHeightFingerprint.join(self.kpis.map(\.heightFingerprint)),
            MenuCardHeightFingerprint.join(self.points.map(\.heightFingerprint)),
            MenuCardHeightFingerprint.join(self.detailLines.map { MenuCardHeightFingerprint.field("detail", $0) }),
        ])
    }
}

extension InlineUsageDashboardModel.KPI {
    fileprivate var heightFingerprint: String {
        MenuCardHeightFingerprint.join([
            MenuCardHeightFingerprint.field("title", self.title),
            MenuCardHeightFingerprint.field("value", self.value),
            self.emphasis ? "1" : "0",
        ])
    }
}

extension InlineUsageDashboardModel.Point {
    fileprivate var heightFingerprint: String {
        MenuCardHeightFingerprint.join([
            self.id,
            MenuCardHeightFingerprint.field("label", self.label),
            MenuCardHeightFingerprint.field("accessibilityValue", self.accessibilityValue),
        ])
    }
}

extension InlineUsageDashboardModel.ValueStyle {
    fileprivate var heightFingerprint: String {
        switch self {
        case .currencyUSD:
            "currencyUSD"
        case let .currency(symbol):
            "currency:\(symbol)"
        case .tokens:
            "tokens"
        case .points:
            "points"
        }
    }
}
