import Foundation

struct UserStatusResponse: Decodable {
    let code: CodeValue?
    let message: String?
    let userStatus: UserStatus?
}

struct CommandModelConfigResponse: Decodable {
    let code: CodeValue?
    let message: String?
    let clientModelConfigs: [ModelConfig]?
}

struct UserStatus: Decodable {
    let email: String?
    let name: String?
    let pro: Bool?
    let g1Tier: String?
    let teamId: String?
    let teamStatus: CodeValue?
    let userUsedPromptCredits: FlexibleInt?
    let userUsedFlowCredits: FlexibleInt?
    let planStatus: PlanStatus?
    let planInfo: PlanInfo?
    let cascadeModelConfigData: ModelConfigData?
    let userTier: UserTier?
}

struct UserTier: Decodable {
    let id: String?
    let name: String?
    let description: String?

    var preferredName: String? {
        guard let value = self.name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return value.isEmpty ? nil : value
    }
}

struct PlanStatus: Decodable {
    let planInfo: PlanInfo?
    let planStart: String?
    let planEnd: String?
    let availablePromptCredits: FlexibleInt?
    let usedPromptCredits: FlexibleInt?
    let availableFlowCredits: FlexibleInt?
    let usedFlowCredits: FlexibleInt?
    let availableFlexCredits: FlexibleInt?
    let usedFlexCredits: FlexibleInt?
    let topUpStatus: TopUpStatus?
}

struct PlanInfo: Decodable {
    let planName: String?
    let planDisplayName: String?
    let displayName: String?
    let productName: String?
    let planShortName: String?
    let teamsTier: CodeValue?
    let monthlyPromptCredits: FlexibleInt?
    let monthlyFlowCredits: FlexibleInt?
    let monthlyFlexCreditPurchaseAmount: FlexibleInt?
    let canBuyMoreCredits: Bool?
    let isTeams: Bool?
    let isEnterprise: Bool?

    var preferredName: String? {
        let candidates = [
            self.planDisplayName,
            self.displayName,
            self.productName,
            self.planName,
            self.planShortName,
        ]
        for candidate in candidates {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if !value.isEmpty { return value }
        }
        return nil
    }
}

struct TopUpStatus: Decodable {
    let topUpTransactionStatus: CodeValue?
    let topUpEnabled: Bool?
    let monthlyTopUpAmount: FlexibleInt?
    let topUpSpent: FlexibleInt?
    let topUpIncrement: FlexibleInt?
    let topUpCriteriaMet: Bool?
}

struct ModelConfigData: Decodable {
    let clientModelConfigs: [ModelConfig]?
}

struct ModelConfig: Decodable {
    let label: String
    let modelOrAlias: ModelAlias
    let quotaInfo: QuotaInfo?
}

struct ModelAlias: Decodable {
    let model: String
}

struct QuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
}

enum CodeValue: Decodable {
    case int(Int)
    case string(String)

    var isOK: Bool {
        switch self {
        case let .int(value):
            value == 0
        case let .string(value):
            value.lowercased() == "ok" || value.lowercased() == "success" || value == "0"
        }
    }

    var rawValue: String {
        switch self {
        case let .int(value): "\(value)"
        case let .string(value): value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported code type")
    }
}

/// Decodes proto3 `int64` / `int32` JSON values serialized as numbers or quoted strings.
struct FlexibleInt: Decodable, Sendable, Equatable {
    let value: Int

    init(_ value: Int) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self.value = intValue
            return
        }
        if let int64Value = try? container.decode(Int64.self),
           let exact = Int(exactly: int64Value)
        {
            self.value = exact
            return
        }
        if let doubleValue = try? container.decode(Double.self),
           doubleValue.isFinite,
           let exact = Int(exactly: doubleValue)
        {
            self.value = exact
            return
        }
        if let stringValue = try? container.decode(String.self) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmed) {
                self.value = intValue
                return
            }
            if let int64Value = Int64(trimmed),
               let exact = Int(exactly: int64Value)
            {
                self.value = exact
                return
            }
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported integer value")
    }
}
