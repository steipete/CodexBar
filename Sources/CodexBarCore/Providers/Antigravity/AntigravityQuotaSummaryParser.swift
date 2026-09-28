import Foundation

// swiftformat:disable:next redundantSendable
struct AntigravityQuotaSummary: Sendable, Equatable {
    let description: String?
    let groups: [AntigravityQuotaSummaryGroup]
}

// swiftformat:disable:next redundantSendable
struct AntigravityQuotaSummaryGroup: Sendable, Equatable {
    let displayName: String
    let description: String?
    let buckets: [AntigravityQuotaSummaryBucket]
}

// swiftformat:disable:next redundantSendable
struct AntigravityQuotaSummaryBucket: Sendable, Equatable {
    let bucketId: String
    let displayName: String
    let remainingFraction: Double?
    let resetTime: Date?
    let resetDescription: String?
    let disabled: Bool
    let window: String?
}

extension AntigravityStatusProbe {
    static func parseQuotaSummaryResponse(_ data: Data) throws -> AntigravityStatusSnapshot {
        try JSONDecoder().decode(AntigravityQuotaSummaryResponse.self, from: data).snapshot()
    }

    static func parseCLIUsageReport(_ data: Data) throws -> AntigravityStatusSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let report = try decoder.decode(QuotaSummaryCLIReport.self, from: data)
        guard report.status == "SUCCESS", report.command.name == "usage" else {
            throw AntigravityStatusProbeError.parseFailed("Unsuccessful CLI usage report")
        }
        let snapshot = try Self.quotaSummarySnapshot(report.command.data)
        guard snapshot.hasKnownQuotaSummary else {
            throw AntigravityStatusProbeError.parseFailed("CLI usage report has no known quota")
        }
        return snapshot
    }

    fileprivate static func quotaSummarySnapshot(
        _ payload: QuotaSummaryPayload,
        accountEmail: String? = nil,
        accountPlan: String? = nil,
        source: AntigravityModelQuotaSource = .local) throws -> AntigravityStatusSnapshot
    {
        let groups = (payload.groups ?? []).compactMap(self.quotaSummaryGroup(from:))
        guard !groups.isEmpty else {
            throw AntigravityStatusProbeError.parseFailed("Missing quota groups")
        }
        return AntigravityStatusSnapshot(
            quotaSummary: AntigravityQuotaSummary(description: payload.description, groups: groups),
            accountEmail: accountEmail,
            accountPlan: accountPlan,
            source: source)
    }

    private static func quotaSummaryGroup(from payload: QuotaSummaryGroupPayload) -> AntigravityQuotaSummaryGroup? {
        let displayName = (payload.displayName ?? payload.name)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let buckets = (payload.buckets ?? []).compactMap(self.quotaSummaryBucket(from:))
        guard !buckets.isEmpty else { return nil }
        return AntigravityQuotaSummaryGroup(
            displayName: self.nonEmpty(displayName) ?? "Quota",
            description: payload.description,
            buckets: buckets)
    }

    private static func quotaSummaryBucket(from payload: QuotaSummaryBucketPayload) -> AntigravityQuotaSummaryBucket? {
        let bucketId = (payload.bucketId ?? payload.id)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (payload.displayName ?? payload.name)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedBucketId = bucketId, !resolvedBucketId.isEmpty else { return nil }
        let resetTime = payload.resetTime.flatMap { Self.parseDate($0) }
        return AntigravityQuotaSummaryBucket(
            bucketId: resolvedBucketId,
            displayName: self.nonEmpty(displayName) ?? resolvedBucketId,
            remainingFraction: payload.remainingFraction ?? payload.remaining?.remainingFraction,
            resetTime: resetTime,
            resetDescription: payload.description,
            disabled: payload.disabled ?? false,
            window: payload.window)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private struct QuotaSummaryCLIReport: Decodable {
    let status: String
    let command: Command

    struct Command: Decodable {
        let name: String
        let data: QuotaSummaryPayload
    }
}

struct AntigravityQuotaSummaryResponse: Decodable {
    private let code: CodeValue?
    private let response: QuotaSummaryPayload?
    private let summary: QuotaSummaryPayload?
    private let description: String?
    private let groups: [QuotaSummaryGroupPayload]?

    func snapshot(
        accountEmail: String? = nil,
        accountPlan: String? = nil,
        source: AntigravityModelQuotaSource = .local) throws -> AntigravityStatusSnapshot
    {
        if let invalid = AntigravityStatusProbe.invalidCode(self.code) {
            throw AntigravityStatusProbeError.apiError(invalid)
        }
        let root = self.groups.map { QuotaSummaryPayload(description: self.description, groups: $0) }
        guard let payload = self.response ?? self.summary ?? root else {
            throw AntigravityStatusProbeError.parseFailed("Missing quota summary")
        }
        return try AntigravityStatusProbe.quotaSummarySnapshot(
            payload, accountEmail: accountEmail, accountPlan: accountPlan, source: source)
    }
}

private struct QuotaSummaryPayload: Decodable {
    let description: String?
    let groups: [QuotaSummaryGroupPayload]?
}

private struct QuotaSummaryGroupPayload: Decodable {
    let displayName: String?
    let name: String?
    let description: String?
    let buckets: [QuotaSummaryBucketPayload]?
}

private struct QuotaSummaryBucketPayload: Decodable {
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
        self.remainingFraction = oneofCase == "remainingFraction"
            ? try container.decodeIfPresent(Double.self, forKey: .value) : nil
    }
}
