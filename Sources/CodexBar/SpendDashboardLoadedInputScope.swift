import Foundation

struct SpendDashboardLoadedInputScope: Equatable, Sendable {
    let bucketTimeZoneIdentifier: String
    let historyDays: Int

    init(
        configuration: SpendDashboardConfiguration,
        input: SpendDashboardModel.ProviderInput)
    {
        self.bucketTimeZoneIdentifier = configuration.bucketCalendar.timeZone.identifier
        self.historyDays = input.snapshot.historyDays
    }
}
