import Foundation

public enum ManusSettingsReader {
    public static func sessionToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let raw = environment["MANUS_SESSION_TOKEN"] ?? environment["manus_session_token"]
        return self.cleaned(raw)
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
