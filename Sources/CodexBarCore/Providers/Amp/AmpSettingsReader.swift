import Foundation

public enum AmpSettingsReader {
    public static let apiTokenKey = "AMP_API_KEY"

    public static func apiToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.apiTokenKey])
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
