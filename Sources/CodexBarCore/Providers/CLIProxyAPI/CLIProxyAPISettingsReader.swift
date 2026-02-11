import Foundation

public enum CLIProxyAPISettingsReader {
    public static let managementURLKey = "CLIPROXYAPI_MANAGEMENT_URL"
    public static let managementKeyKey = "CLIPROXYAPI_MANAGEMENT_KEY"
    public static let authIndexKey = "CLIPROXYAPI_AUTH_INDEX"

    public static func managementKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[managementKeyKey])
    }

    public static func managementURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = self.cleaned(environment[managementURLKey]) else { return nil }
        return self.normalizeBaseURL(raw)
    }

    public static func authIndex(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[authIndexKey])
    }

    public static func normalizeBaseURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let lower = trimmed.lowercased()
        if lower.hasSuffix("/v0/management") {
            trimmed.removeLast("/v0/management".count)
        } else if lower.hasSuffix("/v0/management/") {
            trimmed.removeLast("/v0/management/".count)
        }

        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }

        let normalized: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            normalized = trimmed
        } else {
            normalized = "http://\(trimmed)"
        }

        guard var url = URL(string: normalized) else { return nil }
        if url.path.isEmpty || url.path == "/" {
            url.appendPathComponent("v0")
            url.appendPathComponent("management")
            return url
        }
        if url.path.hasSuffix("/v0/management") {
            return url
        }
        url.appendPathComponent("v0")
        url.appendPathComponent("management")
        return url
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
