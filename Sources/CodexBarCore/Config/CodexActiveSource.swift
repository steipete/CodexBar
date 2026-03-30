import Foundation

public enum CodexActiveSource: Codable, Equatable, Sendable {
    case liveSystem
    case managedAccount(id: UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case accountID
    }

    private enum Kind: String, Codable {
        case liveSystem
        case managedAccount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .liveSystem:
            self = .liveSystem
        case .managedAccount:
            let id = try container.decode(UUID.self, forKey: .accountID)
            self = .managedAccount(id: id)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .liveSystem:
            try container.encode(Kind.liveSystem, forKey: .kind)
        case let .managedAccount(id):
            try container.encode(Kind.managedAccount, forKey: .kind)
            try container.encode(id, forKey: .accountID)
        }
    }
}
