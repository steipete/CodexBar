import Foundation

public enum GroqSettingsReader {
    public static let sessionTokenEnvironmentKey = "GROQ_SESSION_TOKEN"
    public static let orgIDEnvironmentKey = "GROQ_ORG_ID"
    public static let apiURLEnvironmentKey = "GROQ_API_URL"

    public static func sessionToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.sessionTokenEnvironmentKey])
    }

    public static func orgID(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        if let explicit = self.cleaned(environment[self.orgIDEnvironmentKey]) {
            return explicit
        }
        guard let token = self.sessionToken(environment: environment) else { return nil }
        return self.extractOrgID(fromJWT: token)
    }

    public static func apiURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = self.cleaned(environment[self.apiURLEnvironmentKey]),
           let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://api.groq.com")!
    }

    // Decodes the JWT payload (no signature verification) and extracts the org ID
    // from the "https://groq.com/organization" claim.
    static func extractOrgID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        base64 = base64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let orgClaim = json["https://groq.com/organization"] as? [String: Any],
              let orgID = orgClaim["id"] as? String,
              !orgID.isEmpty
        else { return nil }
        return orgID
    }

    static func cleaned(_ raw: String?) -> String? {
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
