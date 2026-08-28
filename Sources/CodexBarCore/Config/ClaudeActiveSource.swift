import Foundation

public enum ClaudeActiveSource: Codable, Equatable, Sendable {
    case ambient
    case profileConfigDir(path: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case configDirPath
    }

    private enum Kind: String, Codable {
        case ambient
        case profileConfigDir
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .ambient:
            self = .ambient
        case .profileConfigDir:
            let path = try container.decode(String.self, forKey: .configDirPath)
            if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self = .ambient
            } else {
                self = .profileConfigDir(path: path)
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ambient:
            try container.encode(Kind.ambient, forKey: .kind)
        case let .profileConfigDir(path):
            try container.encode(Kind.profileConfigDir, forKey: .kind)
            try container.encode(path, forKey: .configDirPath)
        }
    }
}
