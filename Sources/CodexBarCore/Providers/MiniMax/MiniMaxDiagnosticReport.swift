import Foundation

public struct MiniMaxDiagnosticReport: Codable {
    public let schemaVersion: String
    public let generatedAt: Date
    public let provider: String
    public let liveFetch: String
    public let authSourcesPresent: AuthSourcesPresent
    public let endpointsAttempted: [String]
    public let responseShape: [String: String]?
    public let suspectedPlanFields: [String]
    public let suspectedDateFields: [String]
    public let suspectedSubscriptionFields: [String]
    public let redaction: RedactionSummary

    public struct AuthSourcesPresent: Codable, Sendable {
        public let apiTokenEnv: Bool
        public let codingPlanTokenEnv: Bool
        public let cookieHeaderEnv: Bool

        public init(apiTokenEnv: Bool, codingPlanTokenEnv: Bool, cookieHeaderEnv: Bool) {
            self.apiTokenEnv = apiTokenEnv
            self.codingPlanTokenEnv = codingPlanTokenEnv
            self.cookieHeaderEnv = cookieHeaderEnv
        }
    }

    public struct RedactionSummary: Codable, Sendable {
        public let cookies: String
        public let tokens: String
        public let ids: String
        public let emails: String

        public init(cookies: String = "removed", tokens: String = "removed", ids: String = "redacted", emails: String = "redacted") {
            self.cookies = cookies
            self.tokens = tokens
            self.ids = ids
            self.emails = emails
        }
    }

    public init(
        schemaVersion: String = "1.0",
        generatedAt: Date = Date(),
        provider: String = "minimax",
        liveFetch: String = "notPerformed",
        authSourcesPresent: AuthSourcesPresent,
        endpointsAttempted: [String],
        responseShape: [String: String]? = nil,
        suspectedPlanFields: [String],
        suspectedDateFields: [String],
        suspectedSubscriptionFields: [String] = [],
        redaction: RedactionSummary = RedactionSummary())
    {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.provider = provider
        self.liveFetch = liveFetch
        self.authSourcesPresent = authSourcesPresent
        self.endpointsAttempted = endpointsAttempted
        self.responseShape = responseShape
        self.suspectedPlanFields = suspectedPlanFields
        self.suspectedDateFields = suspectedDateFields
        self.suspectedSubscriptionFields = suspectedSubscriptionFields
        self.redaction = redaction
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(formatter.string(from: generatedAt), forKey: .generatedAt)
        try container.encode(provider, forKey: .provider)
        try container.encode(liveFetch, forKey: .liveFetch)
        try container.encode(authSourcesPresent, forKey: .authSourcesPresent)
        try container.encode(endpointsAttempted, forKey: .endpointsAttempted)
        if let shape = responseShape {
            try container.encode(shape, forKey: .responseShape)
        } else {
            try container.encodeNil(forKey: .responseShape)
        }
        try container.encode(suspectedPlanFields, forKey: .suspectedPlanFields)
        try container.encode(suspectedDateFields, forKey: .suspectedDateFields)
        try container.encode(suspectedSubscriptionFields, forKey: .suspectedSubscriptionFields)
        try container.encode(redaction, forKey: .redaction)
    }
}

extension MiniMaxDiagnosticReport {
    public static func detectAuthSources(from environment: [String: String]) -> AuthSourcesPresent {
        AuthSourcesPresent(
            apiTokenEnv: Self.envKeyPresent("MINIMAX_API_KEY", in: environment),
            codingPlanTokenEnv: Self.envKeyPresent("MINIMAX_CODING_API_KEY", in: environment),
            cookieHeaderEnv: Self.envKeyPresent("MINIMAX_COOKIE", in: environment))
    }

    private static func envKeyPresent(_ key: String, in environment: [String: String]) -> Bool {
        guard let value = environment[key] else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "\"\""
    }
}

extension MiniMaxDiagnosticReport {
    public static var suspectedFields: (plan: [String], date: [String], subscription: [String]) {
        (plan: ["planName", "availablePrompts", "currentPrompts", "remainingPrompts", "windowMinutes", "usedPercent"],
         date: ["resetsAt", "updatedAt"],
         subscription: [] as [String])
    }

    public static var safeEndpoints: [String] {
        ["minimax.api", "minimax.web"]
    }
}