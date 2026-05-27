import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    static func kiroUsageNotes(input: Input) -> [String] {
        var notes: [String] = []
        if let authMethod = input.snapshot?.loginMethod(for: .kiro)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !authMethod.isEmpty
        {
            notes.append("\(L("Auth")): \(authMethod)")
        }
        if let overages = input.snapshot?.kiroUsage?.overagesStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !overages.isEmpty
        {
            notes.append("\(L("Overages")): \(overages)")
        }
        let overagesEnabled = input.snapshot?.kiroUsage?.overagesStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("enabled") == true
        if overagesEnabled,
           let overageCreditsUsed = input.snapshot?.kiroUsage?.overageCreditsUsed
        {
            notes.append(
                "\(L("Overage usage")): \(UsageFormatter.kiroCreditNumber(overageCreditsUsed)) \(L("credits"))")
        }
        if overagesEnabled,
           let estimatedOverageCostUSD = input.snapshot?.kiroUsage?.estimatedOverageCostUSD
        {
            notes.append("\(L("Overage cost")): \(UsageFormatter.usdString(estimatedOverageCostUSD))")
        }
        return notes
    }

    static func kiroPlan(snapshot: UsageSnapshot?) -> String? {
        guard let plan = snapshot?.kiroUsage?.displayPlanName,
              !plan.isEmpty
        else { return nil }
        return plan
    }
}
