import Foundation

public enum XAISettingsReader {
    public static let apiKeyEnvironmentKey = "XAI_MANAGEMENT_API_KEY"
    public static let teamIDEnvironmentKey = "XAI_TEAM_ID"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func teamID(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.teamIDEnvironmentKey])
    }

    static func validatedTeamID(environment: [String: String]) throws -> String {
        guard let teamID = self.teamID(environment: environment) else {
            throw XAISettingsError.missingTeamID
        }
        guard !teamID.contains("/"), teamID != ".", teamID != ".." else {
            throw XAISettingsError.invalidTeamID
        }
        return teamID
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public enum XAISettingsError: LocalizedError, Sendable, Equatable {
    case missingTeamID
    case invalidTeamID

    public var errorDescription: String? {
        switch self {
        case .missingTeamID:
            "Missing xAI team ID. Add it in Settings or set XAI_TEAM_ID " +
                "(shown in the xAI Console URL and team settings)."
        case .invalidTeamID:
            "The xAI team ID must be a single identifier without path separators."
        }
    }
}
