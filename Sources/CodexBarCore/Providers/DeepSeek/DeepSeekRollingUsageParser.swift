import Foundation

struct DeepSeekRollingUsage: Sendable, Equatable {
    let tokens: Int?
    let cost: Double?
    let currency: String?

    init(tokens: Int? = nil, cost: Double? = nil, currency: String? = nil) {
        self.tokens = tokens
        self.cost = cost
        self.currency = currency
    }
}

enum DeepSeekRollingUsageParser {
    static func parseAmount(_ data: Data) throws -> Int {
        let payload: DeepSeekByAPIKeyAmountData = try self.decodeBizData(data, label: "rolling amount")
        var total = 0
        for series in payload.series {
            for bucket in series.buckets {
                total = self.addClamped(total, bucket.usage.responseToken.value)
                total = self.addClamped(total, bucket.usage.promptCacheHitToken.value)
                total = self.addClamped(total, bucket.usage.promptCacheMissToken.value)
                total = self.addClamped(total, bucket.usage.promptToken.value)
            }
        }
        return total
    }

    static func parseCost(_ data: Data, preferredCurrency: String?) throws -> (cost: Double, currency: String) {
        let payload: DeepSeekByAPIKeyCostData = try self.decodeBizData(data, label: "rolling cost")
        guard let group = self.preferredCostGroup(payload.data, currency: preferredCurrency) else {
            return (0, preferredCurrency ?? "CNY")
        }
        let total = group.series
            .flatMap(\.buckets)
            .reduce(0) { partial, bucket in
                let value = bucket.cost.value
                return value.isFinite && value > 0 ? partial + value : partial
            }
        return (total, group.currency)
    }

    private static func decodeBizData<Value: Decodable>(_ data: Data, label: String) throws -> Value {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DeepSeekUsageError.parseFailed("\(label): \(error.localizedDescription)")
        }
        guard let envelope = object as? [String: Any] else {
            throw DeepSeekUsageError.parseFailed("\(label): expected an object")
        }
        try self.validateCode(envelope["code"], label: label)
        guard let dataObject = envelope["data"] as? [String: Any] else {
            throw DeepSeekUsageError.parseFailed("\(label): missing data")
        }
        try self.validateCode(dataObject["biz_code"], label: label)
        guard let bizData = dataObject["biz_data"] else {
            throw DeepSeekUsageError.parseFailed("\(label): missing biz_data")
        }
        do {
            let nestedData = try JSONSerialization.data(withJSONObject: bizData)
            return try JSONDecoder().decode(Value.self, from: nestedData)
        } catch let error as DeepSeekUsageError {
            throw error
        } catch {
            throw DeepSeekUsageError.parseFailed("\(label): \(String(describing: error))")
        }
    }

    private static func validateCode(_ rawCode: Any?, label: String) throws {
        guard let rawCode else { return }
        let code: Int? = if let value = rawCode as? Int {
            value
        } else if let value = rawCode as? NSNumber {
            value.intValue
        } else if let value = rawCode as? String {
            Int(value)
        } else {
            nil
        }
        guard let code else {
            throw DeepSeekUsageError.parseFailed("\(label): invalid response code")
        }
        guard code != 0 else { return }
        if code == 40002 || code == 40003 {
            throw DeepSeekUsageError.invalidPlatformToken
        }
        throw DeepSeekUsageError.apiError("\(label) code \(code)")
    }

    private static func preferredCostGroup(
        _ groups: [DeepSeekByAPIKeyCostCurrency],
        currency: String?) -> DeepSeekByAPIKeyCostCurrency?
    {
        if let currency,
           let exact = groups.first(where: { $0.currency.caseInsensitiveCompare(currency) == .orderedSame })
        {
            return exact
        }
        return groups.first
    }

    private static func addClamped(_ lhs: Int, _ rhs: Int) -> Int {
        guard rhs > 0 else { return lhs }
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

private struct DeepSeekByAPIKeyAmountData: Decodable {
    let series: [Series]

    struct Series: Decodable {
        let buckets: [Bucket]
    }

    struct Bucket: Decodable {
        let usage: Usage
    }

    struct Usage: Decodable {
        let responseToken: DeepSeekRollingInteger
        let promptCacheHitToken: DeepSeekRollingInteger
        let promptCacheMissToken: DeepSeekRollingInteger
        let promptToken: DeepSeekRollingInteger

        private enum CodingKeys: String, CodingKey {
            case responseToken = "RESPONSE_TOKEN"
            case promptCacheHitToken = "PROMPT_CACHE_HIT_TOKEN"
            case promptCacheMissToken = "PROMPT_CACHE_MISS_TOKEN"
            case promptToken = "PROMPT_TOKEN"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.responseToken = try container.decodeIfPresent(DeepSeekRollingInteger.self, forKey: .responseToken)
                ?? DeepSeekRollingInteger(value: 0)
            self.promptCacheHitToken = try container.decodeIfPresent(
                DeepSeekRollingInteger.self,
                forKey: .promptCacheHitToken) ?? DeepSeekRollingInteger(value: 0)
            self.promptCacheMissToken = try container.decodeIfPresent(
                DeepSeekRollingInteger.self,
                forKey: .promptCacheMissToken) ?? DeepSeekRollingInteger(value: 0)
            self.promptToken = try container.decodeIfPresent(DeepSeekRollingInteger.self, forKey: .promptToken)
                ?? DeepSeekRollingInteger(value: 0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case series
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.series = try container.decodeIfPresent([Series].self, forKey: .series) ?? []
    }
}

private struct DeepSeekByAPIKeyCostData: Decodable {
    let data: [DeepSeekByAPIKeyCostCurrency]

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.data = try container.decodeIfPresent([DeepSeekByAPIKeyCostCurrency].self, forKey: .data) ?? []
    }
}

private struct DeepSeekByAPIKeyCostCurrency: Decodable {
    let currency: String
    let series: [Series]

    struct Series: Decodable {
        let buckets: [Bucket]
    }

    struct Bucket: Decodable {
        let cost: DeepSeekRollingDouble
    }
}

private struct DeepSeekRollingInteger: Decodable {
    let value: Int

    init(value: Int) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self.value = max(0, value)
            return
        }
        if let value = try? container.decode(String.self), let parsed = Int(value) {
            self.value = max(0, parsed)
            return
        }
        self.value = 0
    }
}

private struct DeepSeekRollingDouble: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self.value = value
            return
        }
        if let value = try? container.decode(String.self), let parsed = Double(value) {
            self.value = parsed
            return
        }
        self.value = 0
    }
}
