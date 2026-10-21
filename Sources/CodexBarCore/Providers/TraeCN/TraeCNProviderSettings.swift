import Foundation

public struct TraeCNProviderSettings: ProviderCookieSettings {
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?

    public init(cookieSource: ProviderCookieSource, manualCookieHeader: String?) {
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
    }
}

public enum TraeCNProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.traecn
    public typealias Section = TraeCNProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias TraeCNProviderSettings = CodexBarCore.TraeCNProviderSettings
    public var traecn: TraeCNProviderSettings? {
        self[TraeCNProviderSettingsKey.self]
    }

    public static func make(traecn: TraeCNProviderSettings?) -> Self {
        self.make(traecn, for: TraeCNProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func traecn(_ section: TraeCNProviderSettings) -> Self {
        Self(section, for: TraeCNProviderSettingsKey.self)
    }
}
