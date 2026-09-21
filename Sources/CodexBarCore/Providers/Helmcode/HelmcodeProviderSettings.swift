import Foundation

public struct HelmcodeProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?
    public let manualTenant: String

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.init(cookieSource: cookieSource, manualCookieHeader: manualCookieHeader, manualTenant: nil)
    }

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?, manualTenant: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
        self.manualTenant = manualTenant == "nanBuilders" ? "nanBuilders" : "helmcode"
    }
}

public enum HelmcodeProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.helmcode
    public typealias Section = HelmcodeProviderSettings
}
