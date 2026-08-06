import Foundation

/// Associates one provider instance with its concrete runtime settings payload.
public protocol ProviderSettingsSectionKey: Sendable {
    associatedtype Section: Sendable

    static var providerID: ProviderInstanceID { get }
}

public struct ProviderSettingsSnapshot: Sendable {
    private let sections: [ProviderInstanceID: any Sendable]

    public let debugMenuEnabled: Bool
    public let debugKeepCLISessionsAlive: Bool

    public init(
        debugMenuEnabled: Bool = false,
        debugKeepCLISessionsAlive: Bool = false,
        contributions: [ProviderSettingsSnapshotContribution] = [])
    {
        self.debugMenuEnabled = debugMenuEnabled
        self.debugKeepCLISessionsAlive = debugKeepCLISessionsAlive
        self.sections = Dictionary(
            contributions.map { ($0.providerID, $0.section) },
            uniquingKeysWith: { _, new in new })
    }

    public init<Key: ProviderSettingsSectionKey>(
        _ section: Key.Section,
        for key: Key.Type,
        debugMenuEnabled: Bool = false,
        debugKeepCLISessionsAlive: Bool = false)
    {
        self.init(
            debugMenuEnabled: debugMenuEnabled,
            debugKeepCLISessionsAlive: debugKeepCLISessionsAlive,
            contributions: [ProviderSettingsSnapshotContribution(section, for: key)])
    }

    public static func make<Key: ProviderSettingsSectionKey>(
        _ section: Key.Section?,
        for key: Key.Type) -> ProviderSettingsSnapshot
    {
        guard let section else { return ProviderSettingsSnapshot() }
        return ProviderSettingsSnapshot(section, for: key)
    }

    public static func make() -> ProviderSettingsSnapshot {
        ProviderSettingsSnapshot()
    }

    public subscript<Key: ProviderSettingsSectionKey>(key: Key.Type) -> Key.Section? {
        self.sections[key.providerID] as? Key.Section
    }

    func contains(_ registration: ProviderSettingsSectionRegistration) -> Bool {
        guard let section = self.sections[registration.providerID] else { return false }
        return ObjectIdentifier(type(of: section)) == registration.sectionTypeID
    }
}

public struct ProviderSettingsSnapshotContribution: Sendable {
    public let providerID: ProviderInstanceID
    let section: any Sendable
    let sectionTypeID: ObjectIdentifier

    public init<Key: ProviderSettingsSectionKey>(_ section: Key.Section, for key: Key.Type) {
        self.providerID = key.providerID
        self.section = section
        self.sectionTypeID = ObjectIdentifier(Key.Section.self)
    }

    init(providerID: ProviderInstanceID, section: some Sendable) {
        self.providerID = providerID
        self.section = section
        self.sectionTypeID = ObjectIdentifier(type(of: section))
    }
}

public struct ProviderSettingsSectionRegistration: Sendable {
    public let providerID: ProviderInstanceID
    let sectionTypeID: ObjectIdentifier
    public let defaultContribution: ProviderSettingsSnapshotContribution?
    private let cookieSettingsReader: @Sendable (ProviderSettingsSnapshot) -> CookieProviderSettings?
    private let credentialContributionReader: @Sendable (
        ProviderCredentialSettingsContext) -> ProviderSettingsSnapshotContribution?

    public init<Key: ProviderSettingsSectionKey>(_ key: Key.Type) {
        self.providerID = key.providerID
        self.sectionTypeID = ObjectIdentifier(Key.Section.self)
        self.defaultContribution = nil
        self.cookieSettingsReader = { _ in nil }
        self.credentialContributionReader = { _ in nil }
    }

    public init<Key: ProviderSettingsSectionKey>(
        _ key: Key.Type,
        cookieSettings: @escaping @Sendable (Key.Section) -> CookieProviderSettings?,
        credentialSettings: @escaping @Sendable (ProviderCredentialSettingsContext) -> Key.Section? = { _ in nil })
    {
        self.providerID = key.providerID
        self.sectionTypeID = ObjectIdentifier(Key.Section.self)
        self.defaultContribution = nil
        self.cookieSettingsReader = { snapshot in
            snapshot[key].flatMap(cookieSettings)
        }
        self.credentialContributionReader = { context in
            credentialSettings(context).map { ProviderSettingsSnapshotContribution($0, for: key) }
        }
    }

    public init<Key: ProviderSettingsSectionKey>(
        _ key: Key.Type,
        credentialSettings: @escaping @Sendable (ProviderCredentialSettingsContext) -> Key.Section?)
    {
        self.init(key, cookieSettings: { _ in nil }, credentialSettings: credentialSettings)
    }

    public init<Key: ProviderSettingsSectionKey>(
        _ key: Key.Type,
        cookieSettings _: Key.Section.Type) where Key.Section: ProviderCookieSettings
    {
        self.init(
            key,
            cookieSettings: { settings in
                CookieProviderSettings(
                    cookieSource: settings.cookieSource,
                    manualCookieHeader: settings.manualCookieHeader)
            },
            credentialSettings: { context in
                guard let provider = key.providerID.firstPartyProvider else { return nil }
                let settings = context.cookieSettings(for: provider)
                return Key.Section(
                    cookieSource: settings.cookieSource,
                    manualCookieHeader: settings.manualCookieHeader)
            })
    }

    static func empty(for providerID: ProviderInstanceID) -> Self {
        let contribution = ProviderSettingsSnapshotContribution(
            providerID: providerID,
            section: EmptyProviderSettingsSection())
        return Self(
            providerID: providerID,
            sectionTypeID: contribution.sectionTypeID,
            defaultContribution: contribution,
            cookieSettingsReader: { _ in nil },
            credentialContributionReader: { _ in nil })
    }

    private init(
        providerID: ProviderInstanceID,
        sectionTypeID: ObjectIdentifier,
        defaultContribution: ProviderSettingsSnapshotContribution?,
        cookieSettingsReader: @escaping @Sendable (ProviderSettingsSnapshot) -> CookieProviderSettings?,
        credentialContributionReader: @escaping @Sendable (
            ProviderCredentialSettingsContext) -> ProviderSettingsSnapshotContribution?)
    {
        self.providerID = providerID
        self.sectionTypeID = sectionTypeID
        self.defaultContribution = defaultContribution
        self.cookieSettingsReader = cookieSettingsReader
        self.credentialContributionReader = credentialContributionReader
    }

    public func accepts(_ contribution: ProviderSettingsSnapshotContribution) -> Bool {
        contribution.providerID == self.providerID && contribution.sectionTypeID == self.sectionTypeID
    }

    public func canRead(from snapshot: ProviderSettingsSnapshot) -> Bool {
        snapshot.contains(self)
    }

    public func cookieSettings(from snapshot: ProviderSettingsSnapshot) -> CookieProviderSettings? {
        self.cookieSettingsReader(snapshot)
    }

    public func credentialContribution(
        context: ProviderCredentialSettingsContext) -> ProviderSettingsSnapshotContribution?
    {
        self.credentialContributionReader(context)
    }
}

public struct ProviderSettingsSnapshotBuilder: Sendable {
    public var debugMenuEnabled: Bool
    public var debugKeepCLISessionsAlive: Bool
    private var contributions: [ProviderSettingsSnapshotContribution] = []

    public init(debugMenuEnabled: Bool = false, debugKeepCLISessionsAlive: Bool = false) {
        self.debugMenuEnabled = debugMenuEnabled
        self.debugKeepCLISessionsAlive = debugKeepCLISessionsAlive
    }

    public mutating func apply(_ contribution: ProviderSettingsSnapshotContribution) {
        self.contributions.append(contribution)
    }

    public func build() -> ProviderSettingsSnapshot {
        ProviderSettingsSnapshot(
            debugMenuEnabled: self.debugMenuEnabled,
            debugKeepCLISessionsAlive: self.debugKeepCLISessionsAlive,
            contributions: self.contributions)
    }
}

private struct EmptyProviderSettingsSection: Sendable {}
