import Foundation

struct SpendDashboardLoadedInputScope: Equatable, Sendable {
    let bucketTimeZoneIdentifier: String
    let historyDays: Int
    let ownershipIdentity: String?

    init(
        configuration: SpendDashboardConfiguration,
        input: SpendDashboardModel.ProviderInput)
    {
        self.bucketTimeZoneIdentifier = configuration.bucketCalendar.timeZone.identifier
        self.historyDays = input.snapshot.historyDays
        self.ownershipIdentity = configuration.codexAccountIdentities.first {
            guard let separator = $0.lastIndex(of: "|") else { return false }
            return input.id == "codex:\($0[..<separator])"
        }
    }
}
