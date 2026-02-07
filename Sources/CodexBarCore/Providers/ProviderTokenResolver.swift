import Foundation

public enum ProviderTokenSource: String, Sendable {
    case environment
}

public struct ProviderTokenResolution: Sendable {
    public let token: String
    public let source: ProviderTokenSource

    public init(token: String, source: ProviderTokenSource) {
        self.token = token
        self.source = source
    }
}

public enum ProviderTokenResolver {
    public static func zaiToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.zaiResolution(environment: environment)?.token
    }

    public static func syntheticToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.syntheticResolution(environment: environment)?.token
    }

    public static func copilotToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.copilotResolution(environment: environment)?.token
    }

    public static func minimaxToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.minimaxTokenResolution(environment: environment)?.token
    }

    public static func minimaxCookie(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.minimaxCookieResolution(environment: environment)?.token
    }

    public static func kimiAuthToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.kimiAuthResolution(environment: environment)?.token
    }

    public static func kimiK2Token(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.kimiK2Resolution(environment: environment)?.token
    }

    public static func warpToken(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.warpResolution(environment: environment)?.token
    }

    public static func zaiResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolveEnv(ZaiSettingsReader.apiToken(environment: environment))
    }

    public static func syntheticResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolveEnv(SyntheticSettingsReader.apiKey(environment: environment))
    }

    public static func copilotResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolveEnv(self.cleaned(environment["COPILOT_API_TOKEN"]))
    }

    public static func minimaxTokenResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolveEnv(MiniMaxAPISettingsReader.apiToken(environment: environment))
    }

    public static func minimaxCookieResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolveEnv(MiniMaxSettingsReader.cookieHeader(environment: environment))
    }

    public static func kimiAuthResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        if let resolution = self.resolveEnv(KimiSettingsReader.authToken(environment: environment)) {
            return resolution
        }
        #if os(macOS)
        do {
            let session = try KimiCookieImporter.importSession()
            if let token = session.authToken {
                return ProviderTokenResolution(token: token, source: .environment)
            }
        } catch {
            // No browser cookies found, continue to fallback
        }
        #endif
        return nil
    }

    public static func kimiK2Resolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolveEnv(KimiK2SettingsReader.apiKey(environment: environment))
    }

    public static func warpResolution(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderTokenResolution?
    {
        self.resolveEnv(WarpSettingsReader.apiKey(environment: environment))
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

    private static func resolveEnv(_ token: String?) -> ProviderTokenResolution? {
        guard let token else { return nil }
        return ProviderTokenResolution(token: token, source: .environment)
    }
}
