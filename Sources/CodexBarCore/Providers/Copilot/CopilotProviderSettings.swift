import Foundation

public struct CopilotProviderSettings: Sendable {
    public let apiToken: String?
    public let enterpriseHost: String?
    public let selectedAccountExternalIdentifier: String?
    public let budgetExtrasEnabled: Bool
    public let budgetCookieSource: ProviderCookieSource
    public let manualBudgetCookieHeader: String?

    public init(
        apiToken: String? = nil,
        enterpriseHost: String? = nil,
        selectedAccountExternalIdentifier: String? = nil,
        budgetExtrasEnabled: Bool = false,
        budgetCookieSource: ProviderCookieSource = .auto,
        manualBudgetCookieHeader: String? = nil)
    {
        self.apiToken = apiToken
        self.enterpriseHost = enterpriseHost
        self.selectedAccountExternalIdentifier = selectedAccountExternalIdentifier
        self.budgetExtrasEnabled = budgetExtrasEnabled
        self.budgetCookieSource = budgetCookieSource
        self.manualBudgetCookieHeader = manualBudgetCookieHeader
    }
}

public enum CopilotProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.copilot
    public typealias Section = CopilotProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias CopilotProviderSettings = CodexBarCore.CopilotProviderSettings
    public var copilot: CopilotProviderSettings? {
        self[CopilotProviderSettingsKey.self]
    }

    public static func make(copilot: CopilotProviderSettings?) -> Self {
        self.make(copilot, for: CopilotProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func copilot(_ section: CopilotProviderSettings) -> Self {
        Self(section, for: CopilotProviderSettingsKey.self)
    }
}
