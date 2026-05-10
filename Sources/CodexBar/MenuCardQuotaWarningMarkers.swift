import CodexBarCore

extension CodexConsumerProjection.RateLane {
    var quotaWarningWindow: QuotaWarningWindow {
        switch self {
        case .session:
            .session
        case .weekly:
            .weekly
        }
    }
}

extension UsageMenuCardView.Model {
    static func warningMarkerPercents(thresholds: [Int]?, showUsed: Bool) -> [Double] {
        guard let thresholds, !thresholds.isEmpty else { return [] }
        return QuotaWarningThresholds.active(thresholds)
            .map { showUsed ? 100 - Double($0) : Double($0) }
            .filter { $0 > 0 && $0 < 100 }
    }
}
