import Foundation

public enum SiliconFlowSettingsReader {
    public static let apiKeyEnvironmentKey = "SILICONFLOW_API_KEY"
    public static let baseURLEnvironmentKey = "SILICONFLOW_BASE_URL"
    public static let chinaOrigin = URL(string: "https://api.siliconflow.cn")!
    public static let internationalOrigin = URL(string: "https://api.siliconflow.com")!
    public static var invalidOriginMessage: String {
        UsageFormatter.localized(
            "SiliconFlow API origin must be https://api.siliconflow.cn or https://api.siliconflow.com.")
    }

    public static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = SettingsValue.cleaned(environment[self.baseURLEnvironmentKey]) else {
            return self.chinaOrigin
        }
        return self.normalizedOrigin(raw)
    }

    /// Official account origins only. A trailing `/v1` is accepted and removed; the key is never sent elsewhere.
    public static func normalizedOrigin(_ raw: String) -> URL? {
        guard let url = ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw),
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              let host = url.host?.lowercased(),
              host == "api.siliconflow.cn" || host == "api.siliconflow.com"
        else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.isEmpty || path == "v1" else { return nil }
        return host == "api.siliconflow.cn" ? self.chinaOrigin : self.internationalOrigin
    }

    public static func validate(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard SettingsValue.cleaned(environment[self.baseURLEnvironmentKey]) != nil else { return }
        guard self.baseURL(environment: environment) != nil else {
            throw ProviderFetchClassifiedError(kind: .apiFailure, message: self.invalidOriginMessage)
        }
    }
}
