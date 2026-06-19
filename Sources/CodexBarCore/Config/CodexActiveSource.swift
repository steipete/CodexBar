import Foundation

public enum CodexActiveSource: Codable, Equatable, Sendable {
    case liveSystem
    case managedAccount(id: UUID)
    case profileHome(path: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case accountID
        case homePath
    }

    private enum Kind: String, Codable {
        case liveSystem
        case managedAccount
        case profileHome
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .liveSystem:
            if let path = try container.decodeIfPresent(String.self, forKey: .homePath),
               !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                self = .profileHome(path: path)
            } else {
                self = .liveSystem
            }
        case .managedAccount:
            let id = try container.decode(UUID.self, forKey: .accountID)
            self = .managedAccount(id: id)
        case .profileHome:
            let path = try container.decode(String.self, forKey: .homePath)
            if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self = .liveSystem
            } else {
                self = .profileHome(path: path)
            }
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
        case let .profileHome(path):
            // Released builds only understand liveSystem/managedAccount. Keep the envelope
            // downgrade-readable while newer builds recover the profile selection from homePath.
            try container.encode(Kind.liveSystem, forKey: .kind)
            try container.encode(path, forKey: .homePath)
        }
    }
}
