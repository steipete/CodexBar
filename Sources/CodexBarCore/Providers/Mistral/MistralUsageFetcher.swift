import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MistralUsageFetcher {
    private static let baseURL = URL(string: "https://admin.mistral.ai")!

    public static func fetchUsage(
        cookieHeader: String,
        csrfToken: String?,
        timeout: TimeInterval = 15) async throws -> MistralUsageSnapshot
    {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)

        let usagePath = self.baseURL.appendingPathComponent("/api/billing/v2/usage")
        var components = URLComponents(url: usagePath, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "month", value: "\(month)"),
            URLQueryItem(name: "year", value: "\(year)"),
        ]
        guard let url = components.url else {
            throw MistralUsageError.apiError("Failed to construct URL")
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://admin.mistral.ai/organization/usage", forHTTPHeaderField: "Referer")
        request.setValue("https://admin.mistral.ai", forHTTPHeaderField: "Origin")
        if let csrfToken {
            request.setValue(csrfToken, forHTTPHeaderField: "X-CSRFTOKEN")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MistralUsageError.apiError("Invalid response type")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw MistralUsageError.invalidCredentials
        default:
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw MistralUsageError.apiError("HTTP \(httpResponse.statusCode): \(body)")
        }

        return try Self.parseResponse(data: data, updatedAt: now)
    }

    static func parseResponse(data: Data, updatedAt: Date) throws -> MistralUsageSnapshot {
        let decoder = JSONDecoder()
        let billing: MistralBillingResponse
        do {
            billing = try decoder.decode(MistralBillingResponse.self, from: data)
        } catch {
            throw MistralUsageError.parseFailed(error.localizedDescription)
        }

        let prices = Self.buildPriceIndex(billing.prices ?? [])
        var totalCost: Double = 0
        var totalInput = 0
        var totalOutput = 0
        var totalCached = 0
        var modelCount = 0

        // Aggregate completion tokens
        if let models = billing.completion?.models {
            for (_, modelData) in models {
                modelCount += 1
                let (input, output, cached, cost) = Self.aggregateModel(modelData, prices: prices)
                totalInput += input
                totalOutput += output
                totalCached += cached
                totalCost += cost
            }
        }

        // Aggregate OCR, connectors, audio if present
        for category in [billing.ocr, billing.connectors, billing.audio] {
            if let models = category?.models {
                for (_, modelData) in models {
                    let (_, _, _, cost) = Self.aggregateModel(modelData, prices: prices)
                    totalCost += cost
                }
            }
        }

        // Aggregate libraries_api (pages + tokens)
        for category in [billing.librariesApi?.pages, billing.librariesApi?.tokens] {
            if let models = category?.models {
                for (_, modelData) in models {
                    let (_, _, _, cost) = Self.aggregateModel(modelData, prices: prices)
                    totalCost += cost
                }
            }
        }

        // Aggregate fine_tuning (training + storage)
        for models in [billing.fineTuning?.training, billing.fineTuning?.storage] {
            if let models {
                for (_, modelData) in models {
                    let (_, _, _, cost) = Self.aggregateModel(modelData, prices: prices)
                    totalCost += cost
                }
            }
        }

        let currency = billing.currency ?? "EUR"
        let currencySymbol = billing.currencySymbol ?? "€"

        let startDate = billing.startDate.flatMap { Self.parseDate($0) }
        let endDate = billing.endDate.flatMap { Self.parseDate($0) }

        return MistralUsageSnapshot(
            totalCost: totalCost,
            currency: currency,
            currencySymbol: currencySymbol,
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            totalCachedTokens: totalCached,
            modelCount: modelCount,
            startDate: startDate,
            endDate: endDate,
            updatedAt: updatedAt)
    }

    // MARK: - Private Helpers

    private static func buildPriceIndex(_ prices: [MistralPrice]) -> [String: Double] {
        var index: [String: Double] = [:]
        for price in prices {
            guard let metric = price.billingMetric,
                  let group = price.billingGroup,
                  let priceStr = price.price,
                  let value = Double(priceStr)
            else { continue }
            let key = "\(metric)::\(group)"
            index[key] = value
        }
        return index
    }

    private static func aggregateModel(
        _ data: MistralModelUsageData,
        prices: [String: Double]) -> (input: Int, output: Int, cached: Int, cost: Double)
    {
        var totalInput = 0
        var totalOutput = 0
        var totalCached = 0
        var totalCost: Double = 0

        for entry in data.input ?? [] {
            let tokens = entry.valuePaid ?? entry.value ?? 0
            totalInput += tokens
            if let metric = entry.billingMetric, let group = entry.billingGroup {
                let pricePerToken = prices["\(metric)::\(group)"] ?? 0
                totalCost += Double(tokens) * pricePerToken
            }
        }

        for entry in data.output ?? [] {
            let tokens = entry.valuePaid ?? entry.value ?? 0
            totalOutput += tokens
            if let metric = entry.billingMetric, let group = entry.billingGroup {
                let pricePerToken = prices["\(metric)::\(group)"] ?? 0
                totalCost += Double(tokens) * pricePerToken
            }
        }

        for entry in data.cached ?? [] {
            let tokens = entry.valuePaid ?? entry.value ?? 0
            totalCached += tokens
            if let metric = entry.billingMetric, let group = entry.billingGroup {
                let pricePerToken = prices["\(metric)::\(group)"] ?? 0
                totalCost += Double(tokens) * pricePerToken
            }
        }

        return (totalInput, totalOutput, totalCached, totalCost)
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
