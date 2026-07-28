import Foundation

struct SpendExchangeRateClient: Sendable {
    enum ExchangeRateError: Error, Equatable {
        case invalidResponse
        case invalidRate
    }

    var fetchUSDToGBP: @Sendable () async throws -> Double

    static let live = Self(fetchUSDToGBP: {
        guard let url = URL(string: "https://api.coinbase.com/v2/exchange-rates?currency=USD") else {
            throw ExchangeRateError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw ExchangeRateError.invalidResponse
        }
        return try Self.decodeUSDToGBP(data)
    })

    static func decodeUSDToGBP(_ data: Data) throws -> Double {
        struct Response: Decodable {
            struct Payload: Decodable {
                let currency: String
                let rates: [String: String]
            }

            let data: Payload
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.data.currency.uppercased() == "USD",
              let rawRate = response.data.rates["GBP"],
              let rate = Double(rawRate),
              rate.isFinite,
              (0.01...10).contains(rate)
        else {
            throw ExchangeRateError.invalidRate
        }
        return rate
    }
}
