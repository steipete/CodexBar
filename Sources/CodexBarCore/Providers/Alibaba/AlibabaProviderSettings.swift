import Foundation

public struct AlibabaCodingPlanProviderSettings: Sendable {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?
    public let apiRegion: AlibabaCodingPlanAPIRegion

    public init(
        cookieSource: ProviderCookieSource = .auto,
        manualCookieHeader: String? = nil,
        apiRegion: AlibabaCodingPlanAPIRegion = .international)
    {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
        self.apiRegion = apiRegion
    }
}

public struct AlibabaTokenPlanProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?
    public let apiRegion: AlibabaTokenPlanAPIRegion

    public init(
        cookieSource: ProviderCookieSource = .auto,
        manualCookieHeader: String? = nil,
        apiRegion: AlibabaTokenPlanAPIRegion = .international)
    {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
        self.apiRegion = apiRegion
    }

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.init(cookieSource: cookieSource, manualCookieHeader: manualCookieHeader, apiRegion: .international)
    }
}

public enum AlibabaCodingPlanProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.alibaba
    public typealias Section = AlibabaCodingPlanProviderSettings
}

public enum AlibabaTokenPlanProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.alibabatokenplan
    public typealias Section = AlibabaTokenPlanProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias AlibabaCodingPlanProviderSettings = CodexBarCore.AlibabaCodingPlanProviderSettings
    public typealias AlibabaTokenPlanProviderSettings = CodexBarCore.AlibabaTokenPlanProviderSettings
    public var alibaba: AlibabaCodingPlanProviderSettings? {
        self[AlibabaCodingPlanProviderSettingsKey.self]
    }

    public var alibabaTokenPlan: AlibabaTokenPlanProviderSettings? {
        self[AlibabaTokenPlanProviderSettingsKey.self]
    }

    public static func make(alibaba: AlibabaCodingPlanProviderSettings?) -> Self {
        self.make(alibaba, for: AlibabaCodingPlanProviderSettingsKey.self)
    }

    public static func make(alibabaTokenPlan: AlibabaTokenPlanProviderSettings?) -> Self {
        self.make(alibabaTokenPlan, for: AlibabaTokenPlanProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func alibaba(_ section: AlibabaCodingPlanProviderSettings) -> Self {
        Self(section, for: AlibabaCodingPlanProviderSettingsKey.self)
    }

    public static func alibabaTokenPlan(_ section: AlibabaTokenPlanProviderSettings) -> Self {
        Self(section, for: AlibabaTokenPlanProviderSettingsKey.self)
    }
}
