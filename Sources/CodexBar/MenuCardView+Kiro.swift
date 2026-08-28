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
        return notes
    }

    static func kiroPlan(snapshot: UsageSnapshot?) -> String? {
        guard let plan = snapshot?.detailRow(label: "Plan")?.value,
              !plan.isEmpty
        else { return nil }
        return plan
    }
}
