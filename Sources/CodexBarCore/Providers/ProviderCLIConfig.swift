import Foundation

public struct ProviderCLIConfig: Sendable {
    public let name: String
    public let aliases: [String]
    public let versionDetector: (@Sendable (BrowserDetection) -> String?)?

    public init(
        name: String,
        aliases: [String] = [],
        versionDetector: (@Sendable (BrowserDetection) -> String?)?)
    {
        self.name = name
        self.aliases = aliases
        self.versionDetector = versionDetector
    }
}
