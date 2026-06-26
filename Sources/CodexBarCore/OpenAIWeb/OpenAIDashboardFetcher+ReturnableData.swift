#if os(macOS)
import Foundation

extension OpenAIDashboardFetcher {
    struct ReturnableDashboardDataInput {
        let codeReview: Double?
        let events: [CreditEvent]
        let usageBreakdown: [OpenAIDashboardDailyBreakdown]
        let hasUsageLimits: Bool
        let creditsRemaining: Double?
        let codexCreditLimit: CodexCreditLimitSnapshot?
    }

    nonisolated static func hasReturnableDashboardData(_ input: ReturnableDashboardDataInput) -> Bool {
        input.codeReview != nil
            || !input.events.isEmpty
            || !input.usageBreakdown.isEmpty
            || input.hasUsageLimits
            || input.creditsRemaining != nil
            || input.codexCreditLimit != nil
    }

    nonisolated static func hasAnyDashboardSignal(
        hasReturnableData: Bool,
        creditsHeaderPresent: Bool) -> Bool
    {
        hasReturnableData || creditsHeaderPresent
    }
}
#endif
