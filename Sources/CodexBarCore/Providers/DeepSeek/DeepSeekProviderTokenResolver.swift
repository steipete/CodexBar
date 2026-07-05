import Foundation

extension ProviderTokenResolver {
    public static func deepseekCookie(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.deepseekCookieResolution(environment: environment)?.token
    }

    public static func deepseekCookieResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        guard let token = DeepSeekSettingsReader.platformSession(environment: environment) else {
            return nil
        }
        return ProviderTokenResolution(token: token, source: .environment)
    }
}
