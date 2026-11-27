import Foundation

// swiftformat:disable:next redundantSendable
struct AntigravityQuotaSummary: Sendable, Equatable {
    let description: String?
    let groups: [AntigravityQuotaSummaryGroup]
    let modelAvailabilities: [String: AntigravityModelAvailability]

    init(
        description: String?,
        groups: [AntigravityQuotaSummaryGroup],
        modelAvailabilities: [String: AntigravityModelAvailability] = [:])
    {
        self.description = description
        self.groups = groups
        self.modelAvailabilities = modelAvailabilities
    }
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
    let remainingAmount: Int?
    let resetTime: Date?
    let resetDescription: String?
    let disabled: Bool
    let window: String?
    let refreshWindowLabel: String?

    init(
        bucketId: String,
        displayName: String,
        remainingFraction: Double?,
        remainingAmount: Int? = nil,
        resetTime: Date?,
        resetDescription: String?,
        disabled: Bool,
        window: String?,
        refreshWindowLabel: String? = nil)
    {
        self.bucketId = bucketId
        self.displayName = displayName
        self.remainingFraction = remainingFraction
        self.remainingAmount = remainingAmount
        self.resetTime = resetTime
        self.resetDescription = resetDescription
        self.disabled = disabled
        self.window = window
        self.refreshWindowLabel = refreshWindowLabel
    }
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
        source: AntigravityModelQuotaSource = .local,
        credits: AntigravityCreditsSnapshot? = nil,
        accountMetadata: AntigravityAccountMetadata? = nil) throws -> AntigravityStatusSnapshot
    {
        var groups = (payload.groups ?? []).compactMap(self.quotaSummaryGroup(from:))
        if groups.isEmpty, let rootBuckets = payload.buckets, !rootBuckets.isEmpty {
            let syntheticGroup = QuotaSummaryGroupPayload(
                displayName: "Quota",
                name: nil,
                description: payload.description,
                buckets: rootBuckets)
            groups = [syntheticGroup].compactMap(self.quotaSummaryGroup(from:))
        }
        guard !groups.isEmpty else {
            throw AntigravityStatusProbeError.parseFailed("Missing quota groups")
        }
        let availabilities = Self.modelAvailabilities(from: payload.modelAvailabilities)
        return AntigravityStatusSnapshot(
            quotaSummary: AntigravityQuotaSummary(
                description: payload.description,
                groups: groups,
                modelAvailabilities: availabilities),
            accountEmail: accountEmail,
            accountPlan: accountPlan,
            source: source,
            credits: credits,
            accountMetadata: accountMetadata)
    }

    private static func modelAvailabilities(
        from raw: [String: QuotaSummaryModelAvailabilityPayload]?) -> [String: AntigravityModelAvailability]
    {
        guard let raw, !raw.isEmpty else { return [:] }
        var resolved: [String: AntigravityModelAvailability] = [:]
        for (modelID, payload) in raw {
            let key = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let state = payload.state?.rawValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !state.isEmpty else { continue }
            let explanation = payload.explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
            resolved[key] = AntigravityModelAvailability(
                state: state,
                explanation: explanation?.isEmpty == false ? explanation : nil)
        }
        return resolved
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
        let refreshWindowLabel = payload.refreshWindowLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AntigravityQuotaSummaryBucket(
            bucketId: resolvedBucketId,
            displayName: self.nonEmpty(displayName) ?? resolvedBucketId,
            remainingFraction: payload.remainingFraction ?? payload.remaining?.remainingFraction,
            remainingAmount: payload.remainingAmount?.value ?? payload.remaining?.remainingAmount?.value,
            resetTime: resetTime,
            resetDescription: payload.description,
            disabled: payload.disabled ?? false,
            window: payload.window,
            refreshWindowLabel: self.nonEmpty(refreshWindowLabel))
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
    private let buckets: [QuotaSummaryBucketPayload]?
    private let modelAvailabilities: [String: QuotaSummaryModelAvailabilityPayload]?

    func snapshot(
        accountEmail: String? = nil,
        accountPlan: String? = nil,
        source: AntigravityModelQuotaSource = .local,
        credits: AntigravityCreditsSnapshot? = nil,
        accountMetadata: AntigravityAccountMetadata? = nil) throws -> AntigravityStatusSnapshot
    {
        if let invalid = AntigravityStatusProbe.invalidCode(self.code) {
            throw AntigravityStatusProbeError.apiError(invalid)
        }
        let root: QuotaSummaryPayload? = if self.groups != nil || self.buckets != nil {
            QuotaSummaryPayload(
                description: self.description,
                groups: self.groups,
                buckets: self.buckets,
                modelAvailabilities: self.modelAvailabilities)
        } else {
            nil
        }
        guard let payload = self.response ?? self.summary ?? root else {
            throw AntigravityStatusProbeError.parseFailed("Missing quota summary")
        }
        return try AntigravityStatusProbe.quotaSummarySnapshot(
            payload,
            accountEmail: accountEmail,
            accountPlan: accountPlan,
            source: source,
            credits: credits,
            accountMetadata: accountMetadata)
    }
}

private struct QuotaSummaryPayload: Decodable {
    let description: String?
    let groups: [QuotaSummaryGroupPayload]?
    let buckets: [QuotaSummaryBucketPayload]?
    let modelAvailabilities: [String: QuotaSummaryModelAvailabilityPayload]?
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
    let remainingAmount: FlexibleInt?
    let remaining: QuotaSummaryRemainingPayload?
    let resetTime: String?
    let window: String?
    let refreshWindowLabel: String?

    private enum CodingKeys: String, CodingKey {
        case bucketId
        case id
        case displayName
        case name
        case description
        case disabled
        case remainingFraction
        case remainingAmount
        case remaining
        case resetTime
        case window
        case refreshWindowLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bucketId = try container.decodeIfPresent(String.self, forKey: .bucketId)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled)
        self.remainingFraction = try container.decodeIfPresent(Double.self, forKey: .remainingFraction)
        self.remainingAmount = try? container.decodeIfPresent(FlexibleInt.self, forKey: .remainingAmount)
        self.remaining = try container.decodeIfPresent(QuotaSummaryRemainingPayload.self, forKey: .remaining)
        self.resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime)
        self.window = try container.decodeIfPresent(String.self, forKey: .window)
        self.refreshWindowLabel = try container.decodeIfPresent(String.self, forKey: .refreshWindowLabel)
    }
}

private struct QuotaSummaryModelAvailabilityPayload: Decodable {
    let state: CodeValue?
    let explanation: String?
}

private struct QuotaSummaryRemainingPayload: Decodable {
    let remainingFraction: Double?
    let remainingAmount: FlexibleInt?

    private enum CodingKeys: String, CodingKey {
        case remainingFraction
        case remainingAmount
        case oneofCase = "case"
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let directFraction = try container.decodeIfPresent(Double.self, forKey: .remainingFraction)
        let directAmount = try? container.decodeIfPresent(FlexibleInt.self, forKey: .remainingAmount)
        if directFraction != nil || directAmount != nil {
            self.remainingFraction = directFraction
            self.remainingAmount = directAmount
            return
        }
        let oneofCase = try container.decodeIfPresent(String.self, forKey: .oneofCase)
        switch oneofCase {
        case "remainingFraction", "remaining_fraction":
            self.remainingFraction = try container.decodeIfPresent(Double.self, forKey: .value)
            self.remainingAmount = nil
        case "remainingAmount", "remaining_amount":
            self.remainingFraction = nil
            self.remainingAmount = try? container.decodeIfPresent(FlexibleInt.self, forKey: .value)
        default:
            self.remainingFraction = nil
            self.remainingAmount = nil
        }
    }
}
