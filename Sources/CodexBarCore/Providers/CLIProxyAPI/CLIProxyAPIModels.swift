import Foundation

public struct CLIProxyAPIAuthFilesResponse: Decodable {
    public let files: [CLIProxyAPIAuthFile]
}

public struct CLIProxyAPIAuthTokenClaims: Decodable {
    public let chatgptAccountID: String?
    public let planType: String?
    public let subscriptionActiveStart: String?
    public let subscriptionActiveUntil: String?

    enum CodingKeys: String, CodingKey {
        case chatgptAccountID = "chatgpt_account_id"
        case planType = "plan_type"
        case subscriptionActiveStart = "chatgpt_subscription_active_start"
        case subscriptionActiveUntil = "chatgpt_subscription_active_until"
    }
}

public struct CLIProxyAPIAuthFile: Decodable {
    public let id: String
    public let name: String
    public let provider: String?
    public let type: String?
    public let label: String?
    public let email: String?
    public let account: String?
    public let accountType: String?
    public let authIndex: String?
    public let status: String?
    public let statusMessage: String?
    public let disabled: Bool
    public let unavailable: Bool
    public let idToken: CLIProxyAPIAuthTokenClaims?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case provider
        case type
        case label
        case email
        case account
        case accountType = "account_type"
        case authIndex = "auth_index"
        case status
        case statusMessage = "status_message"
        case disabled
        case unavailable
        case idToken = "id_token"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(String.self, forKey: .id)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        self.id = (id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? (name ?? "") : id ?? ""
        self.name = name ?? self.id
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
        self.account = try container.decodeIfPresent(String.self, forKey: .account)
        self.accountType = try container.decodeIfPresent(String.self, forKey: .accountType)
        self.authIndex = CLIProxyAPIAuthFile.decodeString(container: container, key: .authIndex)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
        self.statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        self.disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        self.unavailable = try container.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        self.idToken = try container.decodeIfPresent(CLIProxyAPIAuthTokenClaims.self, forKey: .idToken)
    }

    private static func decodeString(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys) -> String?
    {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            if value.rounded(.down) == value {
                return String(Int(value))
            }
            return String(value)
        }
        return nil
    }

    public var normalizedProvider: String {
        let raw = (self.provider ?? self.type ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.lowercased()
    }
}

struct CLIProxyAPIApiCallRequest: Encodable {
    let authIndex: String?
    let method: String
    let url: String
    let header: [String: String]?
    let data: String?

    enum CodingKeys: String, CodingKey {
        case authIndex = "auth_index"
        case method
        case url
        case header
        case data
    }
}

struct CLIProxyAPIApiCallResponse: Decodable {
    let statusCode: Int
    let header: [String: [String]]
    let body: String

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case header
        case body
    }
}
