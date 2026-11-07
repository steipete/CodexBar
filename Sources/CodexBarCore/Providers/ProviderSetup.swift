/// Static, provider-owned guidance. A declaration never evaluates credential readiness.
public struct ProviderSetup: Encodable, Equatable, Sendable {
    public enum Status: String, Encodable, Sendable {
        case unknown
        case declared
    }

    public enum Method: String, Encodable, Sendable {
        case deviceCode
        case token
        case apiKey
        case cookieHeader
        case browserSession
    }

    public enum Platform: String, Encodable, Sendable {
        case macOS
        case linux
    }

    /// Each listed field or environment variable is an alternative source for one input.
    /// Paths are relative to a provider config entry; these contain names, never values.
    public struct Input: Encodable, Equatable, Sendable {
        public let id: String
        public let configFields: [String]
        public let environmentVariables: [String]

        public init(id: String, configFields: [String] = [], environmentVariables: [String] = []) {
            self.id = id
            self.configFields = configFields
            self.environmentVariables = environmentVariables
        }
    }

    /// Routes are alternatives. All inputs within a route are required together.
    /// An interactive route may obtain its credential during the described action.
    public struct Route: Encodable, Equatable, Sendable {
        public let id: String
        public let method: Method
        public let platforms: [Platform]
        public let requiredInputs: [Input]
        public let command: String?
        public let hint: String

        public init(
            id: String,
            method: Method,
            platforms: [Platform],
            requiredInputs: [Input] = [],
            command: String? = nil,
            hint: String)
        {
            self.id = id
            self.method = method
            self.platforms = platforms
            self.requiredInputs = requiredInputs
            self.command = command
            self.hint = UsageFormatter.localized(hint)
        }
    }

    /// These routes enable enrichment, not prerequisites for the provider's primary result.
    public struct OptionalCapability: Encodable, Equatable, Sendable {
        public let id: String
        public let hint: String
        public let routes: [Route]

        public init(id: String, hint: String, routes: [Route]) {
            self.id = id
            self.hint = UsageFormatter.localized(hint)
            self.routes = routes
        }
    }

    public static let unknown = ProviderSetup(status: .unknown, routes: [], optionalCapabilities: [])

    public let status: Status
    public let routes: [Route]
    public let optionalCapabilities: [OptionalCapability]

    public init(routes: [Route], optionalCapabilities: [OptionalCapability] = []) {
        self.init(status: .declared, routes: routes, optionalCapabilities: optionalCapabilities)
    }

    private init(status: Status, routes: [Route], optionalCapabilities: [OptionalCapability]) {
        self.status = status
        self.routes = routes
        self.optionalCapabilities = optionalCapabilities
    }
}
