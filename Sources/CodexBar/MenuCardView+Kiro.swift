import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    static func kiroUsageNotes(input: Input) -> [String] {
        var notes: [String] = []
        if let authMethod = input.snapshot?.loginMethod(for: .kiro)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !authMethod.isEmpty
        {
            notes.append("Auth: \(authMethod)")
        }
        if let overages = input.snapshot?.kiroUsage?.overagesStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !overages.isEmpty
        {
            notes.append("Overages: \(overages)")
        }
        return notes
    }

    static func kiroPlan(snapshot: UsageSnapshot?) -> String? {
        guard let plan = snapshot?.kiroUsage?.displayPlanName,
              !plan.isEmpty
        else { return nil }
        return plan
    }

    static func kiroCreditNumber(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.005 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.2f", value)
    }
}
