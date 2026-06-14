import Foundation

public struct ImportedCredentialSource: Codable, Sendable, Identifiable {
    public let id: UUID
    public var platform: String
    public var path: String
    public var format: String
    public var label: String?

    public init(
        id: UUID = UUID(),
        platform: String,
        path: String,
        format: String,
        label: String? = nil)
    {
        self.id = id
        self.platform = platform
        self.path = path
        self.format = format
        self.label = label
    }
}
