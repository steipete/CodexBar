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

/// Returns boundary percentages for work day markers on a weekly progress bar.
/// Only valid when windowMinutes == 10080 (standard 7-day week).
/// nil workDays means feature is disabled.
func workDayMarkerPercents(workDays: Int?, windowMinutes: Int?) -> [Double] {
    guard workDays != nil, windowMinutes == 10080 else { return [] }
    guard let wd = workDays, wd >= 2, wd <= 7 else { return [] }
    return (1..<wd).map { Double($0) * 100.0 / Double(wd) }
}
