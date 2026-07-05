import CodexBarCore
import Foundation

extension UsageStore {
    func appendMiniMaxPlanUtilizationSamples(
        snapshot: UsageSnapshot,
        appendWindow: (_ window: RateWindow?, _ name: PlanUtilizationSeriesName?) -> Void)
    {
        let services = snapshot.minimaxUsage?.services?
            .filter(\.isPrimaryTextQuotaLane) ?? []
        if services.isEmpty {
            appendWindow(snapshot.primary, .session)
            appendWindow(snapshot.secondary, .weekly)
            return
        }

        if let weeklyService = services.first(where: {
            $0.windowType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "weekly"
        }) {
            appendWindow(self.miniMaxRateWindow(for: weeklyService), .weekly)
        }

        let sessionService = services
            .filter {
                let normalized = $0.windowType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized != "weekly" && normalized != "today" && normalized != "今日"
            }
            .min {
                self.miniMaxWindowMinutes(for: $0) < self.miniMaxWindowMinutes(for: $1)
            }
        if let sessionService {
            appendWindow(self.miniMaxRateWindow(for: sessionService), .session)
        }
    }

    private func miniMaxRateWindow(for service: MiniMaxServiceUsage) -> RateWindow {
        RateWindow(
            usedPercent: max(0, min(100, service.percent)),
            windowMinutes: self.miniMaxWindowMinutes(for: service),
            resetsAt: service.resetsAt,
            resetDescription: service.resetDescription)
    }

    private func miniMaxWindowMinutes(for service: MiniMaxServiceUsage) -> Int {
        let windowType = service.windowType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if windowType == "today" || windowType == "今日" {
            return 24 * 60
        }
        if windowType == "weekly" {
            return 7 * 24 * 60
        }
        if let parsed = MiniMaxServiceUsage.parseWindowType(service.windowType).windowMinutes {
            return parsed
        }
        return 300
    }
}
