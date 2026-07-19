import Foundation

public struct KiloOrganization: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let role: String?

    public init(id: String, name: String, role: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
    }
}
