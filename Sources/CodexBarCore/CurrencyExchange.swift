import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Manages currency exchange rates for converting USD-denominated AI model token estimates
/// into user-preferred currencies (GBP, EUR, CNY, JPY, CAD, AUD, etc.).
///
/// Rates are sourced from the ExchangeRate-API (open.er-api.com), a free service
/// aggregating data from central banks and market sources. Rates are updated daily
/// and cached locally for 24 hours. Hardcoded fallback rates are used when the
/// network is unavailable (e.g. first launch offline).
public final class CurrencyExchange: @unchecked Sendable {
    public static let shared = CurrencyExchange()

    /// All currency codes supported by the converter.
    public static let supportedCurrencies: [String] = [
        "USD", "GBP", "EUR", "CNY", "JPY", "KRW", "CAD", "AUD", "HKD", "TWD", "SGD", "INR",
    ]

    private let lock = NSLock()
    /// Hardcoded fallback rates (approximate mid-market rates as of 2025-07).
    /// These are only used when no cached or live rates are available.
    private var rates: [String: Double] = [
        "USD": 1.0,
        "GBP": 0.79,
        "EUR": 0.92,
        "CNY": 7.27,
        "JPY": 154.0,
        "KRW": 1428.90,
        "CAD": 1.38,
        "AUD": 1.55,
        "HKD": 7.80,
        "TWD": 32.30,
        "SGD": 1.34,
        "INR": 84.50,
    ]
    private var lastFetchTime: Date?

    private static let userDefaultsKey = "CodexBar.CurrencyExchangeRates"
    private static let lastFetchKey = "CodexBar.CurrencyExchangeLastFetch"

    public init() {
        self.loadCachedRates()
    }

    /// Converts a USD amount to the specified target currency code.
    /// Returns `nil` when the requested rate is unavailable so callers cannot
    /// accidentally relabel the unchanged amount as the target currency.
    public func convert(usdAmount: Double, to currencyCode: String) -> Double? {
        let code = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty, code != "USD" else { return usdAmount }

        self.lock.lock()
        let rate = self.rates[code]
        self.lock.unlock()

        guard let rate else { return nil }
        return usdAmount * rate
    }

    /// Converts an amount from one currency to another via USD as the pivot.
    /// For example, `convert(amount: 10, from: "GBP", to: "CNY")` converts £10 to yuan.
    /// Returns `nil` when either currency rate is unavailable.
    public func convert(amount: Double, from sourceCurrency: String, to targetCurrency: String) -> Double? {
        let source = sourceCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let target = targetCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !source.isEmpty, !target.isEmpty, source != target else { return amount }

        self.lock.lock()
        let sourceRate = source == "USD" ? 1.0 : self.rates[source]
        let targetRate = target == "USD" ? 1.0 : self.rates[target]
        self.lock.unlock()

        guard let sourceRate, let targetRate, sourceRate > 0 else { return nil }
        let usdAmount = amount / sourceRate
        return usdAmount * targetRate
    }

    /// Returns the exchange rate for a given currency code relative to USD.
    public func rate(for currencyCode: String) -> Double? {
        let code = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { return 1.0 }
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.rates[code]
    }

    private func getLastFetchTime() -> Date? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.lastFetchTime
    }

    private func updateRates(_ newRates: [String: Double]) {
        self.lock.lock()
        for (code, rate) in newRates {
            self.rates[code] = rate
        }
        self.lastFetchTime = Date()
        self.lock.unlock()
    }

    /// Loads cached rates from `UserDefaults`.
    private func loadCachedRates() {
        if let data = UserDefaults.standard.dictionary(forKey: Self.userDefaultsKey) as? [String: Double] {
            self.lock.lock()
            for (key, val) in data {
                self.rates[key] = val
            }
            self.lock.unlock()
        }
        if let timestamp = UserDefaults.standard.object(forKey: Self.lastFetchKey) as? Date {
            self.lastFetchTime = timestamp
        }
    }

    public static func requiresLiveRates(preferredCurrencyCode: String) -> Bool {
        let code = preferredCurrencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code != "AUTO" && code != "USD" && Self.supportedCurrencies.contains(code)
    }

    /// Asynchronously fetches latest rates from open.er-api.com if the user selected a
    /// non-USD currency and the cache is older than 24 hours.
    ///
    /// The ExchangeRate-API free tier provides daily-updated rates sourced from central banks
    /// and financial data providers. This is sufficient for cost estimation purposes.
    /// On failure, the previously cached (or hardcoded fallback) rates remain in use.
    public func fetchLatestRatesIfNeeded(preferredCurrencyCode: String) async {
        guard Self.requiresLiveRates(preferredCurrencyCode: preferredCurrencyCode) else { return }
        if let lastFetch = self.getLastFetchTime(), Date().timeIntervalSince(lastFetch) < 86400 {
            return
        }

        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }

            struct ExchangeResponse: Decodable {
                let result: String
                let rates: [String: Double]?
            }

            let decoded = try JSONDecoder().decode(ExchangeResponse.self, from: data)
            if decoded.result == "success", let newRates = decoded.rates {
                self.updateRates(newRates)

                UserDefaults.standard.set(newRates, forKey: Self.userDefaultsKey)
                UserDefaults.standard.set(Date(), forKey: Self.lastFetchKey)
            }
        } catch {
            // Ignore fetch errors, keep using fallback / cached rates.
        }
    }
}
