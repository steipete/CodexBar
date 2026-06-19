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
    let planStatus: PlanStatus?
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
}

struct PlanInfo: Decodable {
    let planName: String?
    let planDisplayName: String?
    let displayName: String?
    let productName: String?
    let planShortName: String?

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
