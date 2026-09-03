import Foundation

/// Account metadata `muse login` writes beside its credential.
///
/// The secret itself lives in the macOS Keychain (`storage: "keychain"`); this reader deliberately
/// only parses the plaintext metadata file, so resolving a Muse identity never issues a SecItem read
/// and never raises a Keychain prompt.
public struct MuseLocalAuth: Sendable, Equatable {
    public let accountEmail: String?
    public let accountName: String?
    /// `oauth` for `muse login`, `api_key` for `muse auth set`.
    public let mechanism: String?
    public let apiBaseURL: URL?

    public init(accountEmail: String?, accountName: String?, mechanism: String?, apiBaseURL: URL?) {
        self.accountEmail = accountEmail
        self.accountName = accountName
        self.mechanism = mechanism
        self.apiBaseURL = apiBaseURL
    }

    /// Human-readable login source for the identity card.
    public var loginMethod: String {
        switch self.mechanism {
        case "oauth": "Meta account"
        case "api_key": "API key"
        default: "muse CLI"
        }
    }
}

public enum MuseLocalAuthReader {
    /// `~/.config/muse/auth.json`, written by `muse login` / `muse auth set`.
    public static func defaultPath(home: String = NSHomeDirectory()) -> String {
        "\(home)/.config/muse/auth.json"
    }

    public static func read(
        path: String? = nil,
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default) -> MuseLocalAuth?
    {
        let resolved = path ?? self.defaultPath(home: home)
        guard fileManager.fileExists(atPath: resolved),
              let data = fileManager.contents(atPath: resolved)
        else {
            return nil
        }
        return self.parse(data: data)
    }

    static func parse(data: Data) -> MuseLocalAuth? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [String: Any],
              let meta = providers["meta"] as? [String: Any]
        else {
            return nil
        }

        let baseURL = (meta["api_base_url"] as? String)
            .flatMap { ProviderEndpointOverrideValidator().validatedURLAllowingPrivateNetworkHTTP($0) }

        let auth = MuseLocalAuth(
            accountEmail: MuseSettingsReader.cleaned(meta["user_email"] as? String),
            accountName: MuseSettingsReader.cleaned(meta["user_full_name"] as? String),
            mechanism: MuseSettingsReader.cleaned(meta["mechanism"] as? String),
            apiBaseURL: baseURL)

        // An entry with no usable field at all is the same as having no login.
        if auth.accountEmail == nil, auth.accountName == nil, auth.mechanism == nil, auth.apiBaseURL == nil {
            return nil
        }
        return auth
    }
}
