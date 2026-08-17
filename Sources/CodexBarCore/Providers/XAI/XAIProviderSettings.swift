import Foundation

public struct XAIProviderSettings: Sendable {
    public let usageDataSource: ProviderSourceMode
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?
    public let allowGrokCLICredentials: Bool

    public init(
        usageDataSource: ProviderSourceMode,
        cookieSource: ProviderCookieSource,
        manualCookieHeader: String?,
        allowGrokCLICredentials: Bool)
    {
        self.usageDataSource = usageDataSource
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
        self.allowGrokCLICredentials = allowGrokCLICredentials
    }

    public static func resolved(
        pickerSource: ProviderSourceMode,
        tokenAccountToken: String?,
        configuredCookieSource: ProviderCookieSource,
        configuredCookieHeader: String?,
        allowGrokCLICredentials: Bool) -> XAIProviderSettings
    {
        let routing = XAICredentialRouting.resolve(
            tokenAccountToken: tokenAccountToken,
            manualCookieHeader: tokenAccountToken == nil ? configuredCookieHeader : nil)
        let source = self.resolvedSource(
            pickerSource: pickerSource,
            routing: routing,
            hasAccount: tokenAccountToken != nil)
        return XAIProviderSettings(
            usageDataSource: source,
            cookieSource: self.resolvedCookieSource(
                source: source,
                pickerSource: pickerSource,
                configured: configuredCookieSource),
            manualCookieHeader: routing.manualCookieHeader
                ?? (tokenAccountToken == nil ? configuredCookieHeader : nil),
            allowGrokCLICredentials: allowGrokCLICredentials)
    }

    public static func resolvedSource(
        pickerSource: ProviderSourceMode,
        routing: XAICredentialRouting,
        hasAccount: Bool) -> ProviderSourceMode
    {
        switch pickerSource {
        case .web, .oauth, .api:
            return pickerSource
        case .cli, .auto:
            guard hasAccount else { return .auto }
            switch routing {
            case .managementAPI: return .api
            case .oauth: return .oauth
            case .webCookie: return .web
            case .none: return .auto
            }
        }
    }

    public static func resolvedCookieSource(
        source: ProviderSourceMode,
        pickerSource: ProviderSourceMode,
        configured: ProviderCookieSource) -> ProviderCookieSource
    {
        if pickerSource == .web || source == .web {
            return configured
        }
        if source == .oauth || source == .api {
            return .off
        }
        return configured
    }
}

public enum XAIProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.xai
    public typealias Section = XAIProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias XAIProviderSettings = CodexBarCore.XAIProviderSettings
    public var xai: XAIProviderSettings? {
        self[XAIProviderSettingsKey.self]
    }

    public static func make(xai: XAIProviderSettings?) -> Self {
        self.make(xai, for: XAIProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func xai(_ section: XAIProviderSettings) -> Self {
        Self(section, for: XAIProviderSettingsKey.self)
    }
}
