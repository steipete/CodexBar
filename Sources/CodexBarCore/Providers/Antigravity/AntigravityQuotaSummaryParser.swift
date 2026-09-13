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
        let payload = response.rootPayload
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
        let displayName = payload.resolvedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let buckets = (payload.buckets ?? []).compactMap(self.quotaSummaryBucket(from:))
        guard !buckets.isEmpty else { return nil }
        return AntigravityQuotaSummaryGroup(
            displayName: self.nonEmpty(displayName) ?? "Quota",
            description: payload.description,
            buckets: buckets)
    }

    private static func quotaSummaryBucket(from payload: QuotaSummaryBucketPayload) -> AntigravityQuotaSummaryBucket? {
        let bucketId = payload.resolvedBucketId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = payload.resolvedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedBucketId = bucketId, !resolvedBucketId.isEmpty else { return nil }
        let resetTime = payload.resolvedResetTime.flatMap { Self.parseDate($0) }
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
    let summary: QuotaSummaryPayload?
    let description: String?
    let groups: [QuotaSummaryGroupPayload]?
    let command: QuotaSummaryCommandPayload?
    let status: String?
    let responsePayload: QuotaSummaryPayload?

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case response
        case summary
        case description
        case groups
        case command
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decodeIfPresent(CodeValue.self, forKey: .code)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        self.summary = try container.decodeIfPresent(QuotaSummaryPayload.self, forKey: .summary)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.groups = try container.decodeIfPresent([QuotaSummaryGroupPayload].self, forKey: .groups)
        self.command = try container.decodeIfPresent(QuotaSummaryCommandPayload.self, forKey: .command)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
        self.responsePayload = try? container.decodeIfPresent(QuotaSummaryPayload.self, forKey: .response)
    }

    var rootPayload: QuotaSummaryPayload? {
        if let responsePayload {
            return responsePayload
        }
        if let summary {
            return summary
        }
        if let groups {
            return QuotaSummaryPayload(description: self.description, groups: groups)
        }
        if let command, command.name == "usage", let data = command.data {
            return data
        }
        return nil
    }
}

private struct QuotaSummaryCommandPayload: Decodable {
    let name: String?
    let data: QuotaSummaryPayload?
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
    let name: String?
    let description: String?
    let buckets: [QuotaSummaryBucketPayload]?

    var resolvedDisplayName: String? {
        self.displayName ?? self.name
    }
}

private struct QuotaSummaryBucketPayload: Decodable {
    let bucketId: String?
    let id: String?
    let displayName: String?
    let name: String?
    let description: String?
    let disabled: Bool?
    let remainingFraction: Double?
    let remaining_fraction: Double?
    let remaining: QuotaSummaryRemainingPayload?
    let resetTime: String?
    let reset_time: String?

    var resolvedBucketId: String? {
        self.bucketId ?? self.id
    }

    var resolvedDisplayName: String? {
        self.displayName ?? self.name
    }

    var resolvedRemainingFraction: Double? {
        self.remainingFraction ?? self.remaining_fraction ?? self.remaining?.remainingFraction
    }

    var resolvedResetTime: String? {
        self.resetTime ?? self.reset_time
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
