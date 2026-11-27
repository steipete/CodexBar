import Foundation

struct QuotaSummaryPayload: Decodable {
    let description: String?
    let groups: [QuotaSummaryGroupPayload]?
}

struct QuotaSummaryGroupPayload: Decodable {
    let displayName: String?
    let name: String?
    let description: String?
    let buckets: [QuotaSummaryBucketPayload]?
}

struct QuotaSummaryBucketPayload: Decodable {
    let bucketId: String?
    let id: String?
    let displayName: String?
    let name: String?
    let description: String?
    let disabled: Bool?
    let remainingFraction: Double?
    let remaining: QuotaSummaryRemainingPayload?
    let resetTime: String?
    let window: String?
}

struct QuotaSummaryRemainingPayload: Decodable {
    let remainingFraction: Double?

    private enum CodingKeys: String, CodingKey {
        case remainingFraction
        case oneofCase = "case"
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let remainingFraction = try container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
            self.remainingFraction = remainingFraction
            return
        }
        let oneofCase = try container.decodeIfPresent(String.self, forKey: .oneofCase)
        self.remainingFraction = oneofCase == "remainingFraction"
            ? try container.decodeIfPresent(Double.self, forKey: .value) : nil
    }
}
