import Foundation

public struct StepFunProviderSettings: Sendable {
    public let cookieSource: ProviderCookieSource
    public let manualToken: String
    public let username: String
    public let password: String

    public init(
        cookieSource: ProviderCookieSource = .auto,
        manualToken: String = "",
        username: String = "",
        password: String = "")
    {
        self.cookieSource = cookieSource
        self.manualToken = manualToken
        self.username = username
        self.password = password
    }
}

public enum StepFunProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.stepfun
    public typealias Section = StepFunProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias StepFunProviderSettings = CodexBarCore.StepFunProviderSettings
    public var stepfun: StepFunProviderSettings? {
        self[StepFunProviderSettingsKey.self]
    }

    public static func make(stepfun: StepFunProviderSettings?) -> Self {
        self.make(stepfun, for: StepFunProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func stepfun(_ section: StepFunProviderSettings) -> Self {
        Self(section, for: StepFunProviderSettingsKey.self)
    }
}
