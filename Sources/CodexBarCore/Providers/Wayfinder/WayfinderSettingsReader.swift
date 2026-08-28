import Foundation

public enum WayfinderSettingsError: LocalizedError, Equatable, Sendable {
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpointOverride(key):
            "Wayfinder gateway URL override \(key) is invalid. Use an HTTPS URL, or plain HTTP for " +
                "loopback addresses only, without embedded credentials."
        }
    }
}

public enum WayfinderSettingsReader {
    public static let baseURLEnvironmentKey = "WAYFINDER_GATEWAY_URL"
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8088")!

    public static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        guard let raw = self.cleaned(environment[self.baseURLEnvironmentKey]) else {
            return self.defaultBaseURL
        }
        // Loopback HTTP is allowed because the gateway is a local service; the default
        // base URL is plain HTTP on 127.0.0.1. Non-loopback hosts must use HTTPS.
        return ProviderEndpointOverrideValidator().validatedURLAllowingLoopbackHTTP(raw) ?? self.defaultBaseURL
    }

    public static func validateEndpointOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let raw = self.cleaned(environment[self.baseURLEnvironmentKey]) else { return }
        guard ProviderEndpointOverrideValidator().validatedURLAllowingLoopbackHTTP(raw) != nil else {
            throw WayfinderSettingsError.invalidEndpointOverride(self.baseURLEnvironmentKey)
        }
    }

    public static func dashboardURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        self.appending(path: "router", to: self.baseURL(environment: environment))
    }

    static func appending(path: String, to baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = "\(basePath)/\(path)"
        components.query = nil
        components.fragment = nil
        return components.url ?? baseURL
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
