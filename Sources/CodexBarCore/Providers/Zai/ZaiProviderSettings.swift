import Foundation

public enum ZaiUsageScope: String, CaseIterable, Codable, Sendable {
    case personal
    case team
}

public struct ZaiBigModelTeamContext: Equatable, Sendable {
    public let organizationID: String
    public let projectID: String

    public init?(organizationID: String?, projectID: String?) {
        guard let organizationID = ZaiSettingsReader.cleaned(organizationID),
              let projectID = ZaiSettingsReader.cleaned(projectID)
        else { return nil }
        self.organizationID = organizationID
        self.projectID = projectID
    }

    public init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            organizationID: environment[ZaiSettingsReader.bigModelOrganizationKey],
            projectID: environment[ZaiSettingsReader.bigModelProjectKey])
    }
}

public struct ZaiProviderSettings: Sendable {
    public let apiRegion: ZaiAPIRegion
    public let usageScope: ZaiUsageScope
    public let teamContext: ZaiBigModelTeamContext?

    public init(
        apiRegion: ZaiAPIRegion = .global,
        usageScope: ZaiUsageScope = .personal,
        teamContext: ZaiBigModelTeamContext? = nil)
    {
        self.apiRegion = apiRegion
        self.usageScope = usageScope
        self.teamContext = teamContext
    }
}

public enum ZaiProviderSettingsError: LocalizedError, Sendable, Equatable {
    case missingTeamContext

    public var errorDescription: String? {
        "z.ai BigModel team usage requires both Organization ID and Project ID."
    }
}

public enum ZaiProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.zai
    public typealias Section = ZaiProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias ZaiProviderSettings = CodexBarCore.ZaiProviderSettings
    public var zai: ZaiProviderSettings? {
        self[ZaiProviderSettingsKey.self]
    }

    public static func make(zai: ZaiProviderSettings?) -> Self {
        self.make(zai, for: ZaiProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func zai(_ section: ZaiProviderSettings) -> Self {
        Self(section, for: ZaiProviderSettingsKey.self)
    }
}
