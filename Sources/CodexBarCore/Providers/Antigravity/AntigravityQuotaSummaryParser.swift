import Foundation

struct AntigravityQuotaSummary: Sendable, Equatable {
    let description: String?
    let groups: [AntigravityQuotaSummaryGroup]
}

struct AntigravityQuotaSummaryGroup: Sendable, Equatable {
    let displayName: String
    let description: String?
    let buckets: [AntigravityQuotaSummaryBucket]
}

struct AntigravityQuotaSummaryBucket: Sendable, Equatable {
    let bucketId: String
    let displayName: String
    let remainingFraction: Double?
    let resetTime: Date?
    let resetDescription: String?
    let disabled: Bool

    init(
        bucketId: String,
        displayName: String,
        remainingFraction: Double?,
        resetTime: Date? = nil,
        resetDescription: String?,
        disabled: Bool)
    {
        self.bucketId = bucketId
        self.displayName = displayName
        self.remainingFraction = remainingFraction
        self.resetTime = resetTime
        self.resetDescription = resetDescription
        self.disabled = disabled
    }
}

extension AntigravityStatusProbe {
    static func parseQuotaSummaryResponse(_ data: Data) throws -> AntigravityStatusSnapshot {
        let decoder = JSONDecoder()
        let response = try decoder.decode(QuotaSummaryResponse.self, from: data)
        if let invalid = Self.invalidCode(response.code) {
            throw AntigravityStatusProbeError.apiError(invalid)
        }
        let payload = response.response ?? response.summary ?? response.rootPayload
        guard let payload else {
            throw AntigravityStatusProbeError.parseFailed("Missing quota summary")
        }
        let groups = payload.groups.compactMap(self.quotaSummaryGroup(from:))
        guard !groups.isEmpty else {
            throw AntigravityStatusProbeError.parseFailed("Missing quota groups")
        }
        return AntigravityStatusSnapshot(
            quotaSummary: AntigravityQuotaSummary(
                description: payload.description,
                groups: groups),
            accountEmail: nil,
            accountPlan: nil,
            source: .local)
    }

    private static func quotaSummaryGroup(from payload: QuotaSummaryGroupPayload) -> AntigravityQuotaSummaryGroup? {
        let displayName = payload.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let buckets = (payload.buckets ?? []).compactMap(self.quotaSummaryBucket(from:))
        guard !buckets.isEmpty else { return nil }
        return AntigravityQuotaSummaryGroup(
            displayName: self.nonEmpty(displayName) ?? "Quota",
            description: payload.description,
            buckets: buckets)
    }

    private static func quotaSummaryBucket(from payload: QuotaSummaryBucketPayload) -> AntigravityQuotaSummaryBucket? {
        let bucketId = payload.bucketId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = payload.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedBucketId = bucketId, !resolvedBucketId.isEmpty else { return nil }
        let resetTime = payload.resetTime.flatMap { Self.parseDate($0) }
        return AntigravityQuotaSummaryBucket(
            bucketId: resolvedBucketId,
            displayName: self.nonEmpty(displayName) ?? resolvedBucketId,
            remainingFraction: payload.resolvedRemainingFraction,
            resetTime: resetTime,
            resetDescription: payload.description,
            disabled: payload.disabled ?? false)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private struct QuotaSummaryResponse: Decodable {
    let code: CodeValue?
    let message: String?
    let response: QuotaSummaryPayload?
    let summary: QuotaSummaryPayload?
    let description: String?
    let groups: [QuotaSummaryGroupPayload]?

    var rootPayload: QuotaSummaryPayload? {
        guard let groups else { return nil }
        return QuotaSummaryPayload(description: self.description, groups: groups)
    }
}

private struct QuotaSummaryPayload: Decodable {
    let description: String?
    let groups: [QuotaSummaryGroupPayload]

    init(description: String?, groups: [QuotaSummaryGroupPayload]) {
        self.description = description
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey {
        case description
        case groups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.groups = try container.decodeIfPresent([QuotaSummaryGroupPayload].self, forKey: .groups) ?? []
    }
}

private struct QuotaSummaryGroupPayload: Decodable {
    let displayName: String?
    let description: String?
    let buckets: [QuotaSummaryBucketPayload]?
}

private struct QuotaSummaryBucketPayload: Decodable {
    let bucketId: String?
    let displayName: String?
    let description: String?
    let disabled: Bool?
    let remainingFraction: Double?
    let remaining: QuotaSummaryRemainingPayload?
    let resetTime: String?

    var resolvedRemainingFraction: Double? {
        self.remainingFraction ?? self.remaining?.remainingFraction
    }
}

private struct QuotaSummaryRemainingPayload: Decodable {
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
        if oneofCase == "remainingFraction" {
            self.remainingFraction = try container.decodeIfPresent(Double.self, forKey: .value)
        } else {
            self.remainingFraction = nil
        }
    }
}
