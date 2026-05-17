import Foundation

public struct DeepGramSettingsReader: Sendable {
    public static let apiTokenEnvironmentKey = "DEEPGRAM_API_KEY"
    public static let projectIDEnvironmentKey = "DEEPGRAM_PROJECT_ID"

    public static func apiToken(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        self.cleaned(environment[self.apiTokenEnvironmentKey])
    }

    public static func projectID(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        self.cleaned(environment[self.projectIDEnvironmentKey])
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
