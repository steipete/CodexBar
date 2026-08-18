import Foundation

public enum GrokSettingsReader {
    public static let oauthTokenEnvironmentKey = "GROK_OAUTH_TOKEN"

    public static func oauthAccessToken(
        environment: [String: String],
        settings _: ProviderSettingsSnapshot? = nil) -> String?
    {
        GrokCredentialRouting.normalizedOAuthToken(environment[self.oauthTokenEnvironmentKey])
    }

    public static func pastedCredentials(
        environment: [String: String],
        settings: ProviderSettingsSnapshot? = nil) -> GrokCredentials?
    {
        guard let token = self.oauthAccessToken(environment: environment, settings: settings) else {
            return nil
        }
        return GrokCredentials.pasted(accessToken: token)
    }

    public static func resolvedCredentials(
        environment: [String: String],
        settings: ProviderSettingsSnapshot? = nil) -> GrokCredentials?
    {
        if let pasted = self.pastedCredentials(environment: environment, settings: settings) {
            return pasted
        }
        if let file = try? GrokCredentialsStore.load(env: environment), !file.isExpired {
            return file
        }
        return nil
    }

    public static func normalizedOAuthToken(_ raw: String?) -> String? {
        GrokCredentialRouting.normalizedOAuthToken(raw)
    }
}
