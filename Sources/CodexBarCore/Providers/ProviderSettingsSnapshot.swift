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

    public init<Key: ProviderSettingsSectionKey>(_ key: Key.Type) {
        self.providerID = key.providerID
        self.sectionTypeID = ObjectIdentifier(Key.Section.self)
        self.defaultContribution = nil
    }

    static func empty(for providerID: ProviderInstanceID) -> Self {
        let contribution = ProviderSettingsSnapshotContribution(
            providerID: providerID,
            section: EmptyProviderSettingsSection())
        return Self(
            providerID: providerID,
            sectionTypeID: contribution.sectionTypeID,
            defaultContribution: contribution)
    }

    private init(
        providerID: ProviderInstanceID,
        sectionTypeID: ObjectIdentifier,
        defaultContribution: ProviderSettingsSnapshotContribution?)
    {
        self.providerID = providerID
        self.sectionTypeID = sectionTypeID
        self.defaultContribution = defaultContribution
    }

    public func accepts(_ contribution: ProviderSettingsSnapshotContribution) -> Bool {
        contribution.providerID == self.providerID && contribution.sectionTypeID == self.sectionTypeID
    }

    public func canRead(from snapshot: ProviderSettingsSnapshot) -> Bool {
        snapshot.contains(self)
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
