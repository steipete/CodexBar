import Foundation

public struct MuseSettingsReader: Sendable {
    public static let apiKeyEnvironmentKey = "META_API_KEY"
    public static let fallbackApiKeyEnvironmentKey = "MUSE_API_KEY"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configURL: URL? = nil) -> String?
    {
        if let key = self.cleaned(environment[self.apiKeyEnvironmentKey]) { return key }
        if let key = self.cleaned(environment[self.fallbackApiKeyEnvironmentKey]) { return key }
        if let key = self.readAPIKeyFromConfigFile(configURL: configURL, environment: environment) { return key }
        return nil
    }

    public static func defaultSessionRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL]
    {
        if let customDir = environment["MUSE_SESSIONS_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customDir.isEmpty
        {
            return [URL(fileURLWithPath: customDir, isDirectory: true)]
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".local/share/muse/sessions", isDirectory: true),
            home.appendingPathComponent(".config/muse/sessions", isDirectory: true),
            home.appendingPathComponent(".muse/sessions", isDirectory: true),
            home.appendingPathComponent(".config/muse/logs", isDirectory: true),
        ]
    }

    public struct MuseSettings: Sendable {
        public let apiKey: String?
        public let isContributor: Bool
        public let defaultModel: String?
        public let planName: String?
        public let email: String?

        public init(
            apiKey: String?,
            isContributor: Bool,
            defaultModel: String? = nil,
            planName: String? = nil,
            email: String? = nil)
        {
            self.apiKey = apiKey
            self.isContributor = isContributor
            self.defaultModel = defaultModel
            self.planName = planName
            self.email = email
        }
    }

    public static func readSettings(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configURL: URL? = nil) -> MuseSettings
    {
        let obj = self.readSettingsJSON(configURL: configURL)
        let key = self.apiKey(environment: environment, configURL: configURL)
        let tier = (obj?["tier"] as? String) ?? (obj?["plan"] as? String)
        let isContributor = tier?.lowercased().contains("contributor") == true
        let defaultModel = (obj?["model"] as? String) ?? (obj?["default_model"] as? String)
        let planName = (obj?["plan"] as? String) ?? (obj?["tier"] as? String)
        let email = (obj?["email"] as? String) ?? (obj?["user"] as? String)

        return MuseSettings(
            apiKey: key,
            isContributor: isContributor,
            defaultModel: defaultModel,
            planName: planName,
            email: email)
    }

    public static func readSettingsJSON(
        configURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: Any]?
    {
        let fileURL: URL = {
            if let configURL { return configURL }
            if let customPath = environment["MUSE_CONFIG_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !customPath.isEmpty
            {
                return URL(fileURLWithPath: customPath, isDirectory: false)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/muse/settings.json", isDirectory: false)
        }()
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        return obj
    }

    private static func readAPIKeyFromConfigFile(
        configURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        guard let obj = self.readSettingsJSON(configURL: configURL, environment: environment) else { return nil }
        if let key = obj["apiKey"] as? String {
            return self.cleaned(key)
        }
        if let key = obj["meta_api_key"] as? String {
            return self.cleaned(key)
        }
        if let key = obj["api_key"] as? String {
            return self.cleaned(key)
        }
        return nil
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
