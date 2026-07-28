import CodexBarCore
import Foundation

extension UsageStore {
    static let spendExchangeRateRefreshInterval: Duration = .seconds(15 * 60)

    func startSpendExchangeRateUpdates(client: SpendExchangeRateClient = .live) {
        self.spendExchangeRateTask?.cancel()
        self.spendExchangeRateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshSpendExchangeRate(client: client)
                do {
                    try await Task.sleep(for: Self.spendExchangeRateRefreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    func refreshSpendExchangeRate(client: SpendExchangeRateClient = .live) async {
        do {
            let rate = try await spendDashboardUSDToGBPRate(client.fetchUSDToGBP())
            self.settings.userDefaults.set(
                true,
                forKey: SpendDisplayCurrencyPreference.displayGBPDefaultsKey)
            self.settings.userDefaults.set(
                rate,
                forKey: SpendDisplayCurrencyPreference.usdToGBPRateDefaultsKey)
            self.settings.userDefaults.set(
                Date(),
                forKey: SpendDisplayCurrencyPreference.rateUpdatedAtDefaultsKey)
            self.spendDisplayCurrencyDidChange(reason: "live-rate")
        } catch is CancellationError {
            return
        } catch {
            CodexBarLog.logger(LogCategories.app).warning(
                "USD to GBP exchange-rate refresh failed",
                metadata: ["error": String(describing: error)])
        }
    }

    func spendDisplayCurrencyDidChange(reason: String) {
        self.spendCurrencyRevision &+= 1
        self.persistWidgetSnapshot(reason: reason)
    }
}
