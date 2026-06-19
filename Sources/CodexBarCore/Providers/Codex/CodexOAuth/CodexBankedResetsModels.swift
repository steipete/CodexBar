import Foundation

public struct CodexBankedResetsResponse: Decodable, Equatable, Sendable {
    public let resets: [CodexBankedReset]
    public let availableCount: Int?

    enum CodingKeys: String, CodingKey {
        case resets = "credits"
        case availableCount = "available_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.availableCount = try container.decodeIfPresent(Int.self, forKey: .availableCount)
        let decodedResets = try container.decodeIfPresent([LossyBankedReset].self, forKey: .resets) ?? []
        self.resets = decodedResets.compactMap(\.value)
    }

    public static func decodeEndpointPayload(_ data: Data) throws -> CodexBankedResetsResponse {
        try JSONDecoder().decode(CodexBankedResetsResponse.self, from: data)
    }

    public func snapshot(updatedAt: Date) -> CodexBankedResetsSnapshot {
        CodexBankedResetsSnapshot(
            resets: self.resets,
            availableCount: self.availableCount,
            updatedAt: updatedAt)
    }

    private struct LossyBankedReset: Decodable {
        let value: CodexBankedReset?

        init(from decoder: Decoder) throws {
            self.value = try? CodexBankedReset(from: decoder)
        }
    }
}

public struct CodexBankedResetsSnapshot: Equatable, Sendable {
    public let resets: [CodexBankedReset]
    private let endpointAvailableCount: Int?
    public let updatedAt: Date

    public init(resets: [CodexBankedReset], availableCount: Int?, updatedAt: Date) {
        self.resets = resets
        self.endpointAvailableCount = availableCount
        self.updatedAt = updatedAt
    }

    public var availableCount: Int {
        self.endpointAvailableCount ?? self.availableResets.count
    }

    public var availableResets: [CodexBankedReset] {
        self.resets
            .filter { $0.isAvailable(referenceDate: self.updatedAt) }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (lhs?, rhs?):
                    lhs < rhs
                case (_?, nil):
                    true
                case (nil, _?):
                    false
                case (nil, nil):
                    lhs.id < rhs.id
                }
            }
    }

    public var nextExpiry: Date? {
        self.availableResets.compactMap(\.expiresAt).min()
    }
}

public struct CodexBankedReset: Decodable, Equatable, Sendable {
    public let id: String
    public let resetType: String?
    public let status: CodexBankedResetStatus
    public let grantedAt: Date?
    public let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case resetType = "reset_type"
        case status
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
    }

    public init(id: String, resetType: String?, status: CodexBankedResetStatus, grantedAt: Date?, expiresAt: Date?) {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.resetType = try? container.decodeIfPresent(String.self, forKey: .resetType)
        self.status = (try? container.decode(CodexBankedResetStatus.self, forKey: .status)) ?? .unknown("")
        self.grantedAt = Self.decodeDate(container, forKey: .grantedAt)
        self.expiresAt = Self.decodeDate(container, forKey: .expiresAt)
    }

    func isAvailable(referenceDate: Date) -> Bool {
        guard !self.status.isUnavailable else { return false }
        if let expiresAt {
            return expiresAt > referenceDate
        }
        return true
    }

    private static func decodeDate(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Date? {
        guard let value = try? container.decodeIfPresent(String.self, forKey: key), !value.isEmpty else { return nil }
        return Self.parseDate(value)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

public enum CodexBankedResetStatus: Equatable, Sendable {
    case available
    case redeemed
    case expired
    case unknown(String)

    fileprivate var isUnavailable: Bool {
        switch self {
        case .redeemed, .expired, .unknown:
            true
        case .available:
            false
        }
    }
}

extension CodexBankedResetStatus: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "available":
            self = .available
        case "redeemed":
            self = .redeemed
        case "expired":
            self = .expired
        default:
            self = .unknown(value)
        }
    }
}
