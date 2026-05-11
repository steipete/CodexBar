import CodexBarCore
import Foundation

extension SettingsStore {
    var kiloUsageDataSource: KiloUsageDataSource {
        get {
            let source = self.configSnapshot.providerConfig(for: .kilo)?.source
            return Self.kiloUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .api: .api
            case .cli: .cli
            }
            self.updateProviderConfig(provider: .kilo) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .kilo, field: "usageSource", value: newValue.rawValue)
        }
    }

    var kiloExtrasEnabled: Bool {
        get {
            guard self.kiloUsageDataSource == .auto else { return false }
            return self.kiloExtrasEnabledRaw
        }
        set {
            self.kiloExtrasEnabledRaw = newValue
        }
    }

    var kiloAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .kilo)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .kilo) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .kilo, field: "apiKey", value: newValue)
        }
    }

    private var kiloExtrasEnabledRaw: Bool {
        get { self.configSnapshot.providerConfig(for: .kilo)?.extrasEnabled ?? false }
        set {
            self.updateProviderConfig(provider: .kilo) { entry in
                entry.extrasEnabled = newValue
            }
            self.logProviderModeChange(
                provider: .kilo,
                field: "extrasEnabled",
                value: newValue ? "1" : "0")
        }
    }
}

extension SettingsStore {
    func kiloSettingsSnapshot(tokenOverride _: TokenAccountOverride?) -> ProviderSettingsSnapshot.KiloProviderSettings {
        ProviderSettingsSnapshot.KiloProviderSettings(
            usageDataSource: self.kiloUsageDataSource,
            extrasEnabled: self.kiloExtrasEnabled)
    }

    private static func kiloUsageDataSource(from source: ProviderSourceMode?) -> KiloUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .web, .oauth:
            return .auto
        case .api:
            return .api
        case .cli:
            return .cli
        }
    }
}

extension SettingsStore {
    var kiloKnownOrganizations: [KiloOrganization] {
        get { self.configSnapshot.providerConfig(for: .kilo)?.kiloKnownOrganizations ?? [] }
        set {
            self.updateProviderConfig(provider: .kilo) { entry in
                entry.kiloKnownOrganizations = newValue.isEmpty ? nil : newValue
            }
        }
    }

    var kiloEnabledOrganizationIDs: [String] {
        get { self.configSnapshot.providerConfig(for: .kilo)?.kiloEnabledOrganizationIDs ?? [] }
        set {
            let cleaned = Array(KiloOrgIDLinkedHashSet(newValue
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }))
            self.updateProviderConfig(provider: .kilo) { entry in
                entry.kiloEnabledOrganizationIDs = cleaned.isEmpty ? nil : cleaned
            }
            self.logProviderModeChange(
                provider: .kilo,
                field: "enabledOrganizations",
                value: cleaned.joined(separator: ","))
        }
    }

    func setKiloKnownOrganizationsPruningEnabled(_ orgs: [KiloOrganization]) {
        self.kiloKnownOrganizations = orgs
        let validIDs = Set(orgs.map(\.id))
        let pruned = self.kiloEnabledOrganizationIDs.filter { validIDs.contains($0) }
        if pruned != self.kiloEnabledOrganizationIDs {
            self.kiloEnabledOrganizationIDs = pruned
        }
    }

    func kiloIsOrganizationEnabled(_ orgID: String) -> Bool {
        self.kiloEnabledOrganizationIDs.contains(orgID)
    }

    func setKiloOrganization(_ orgID: String, enabled: Bool) {
        var current = self.kiloEnabledOrganizationIDs
        if enabled {
            guard !current.contains(orgID) else { return }
            current.append(orgID)
        } else {
            current.removeAll { $0 == orgID }
        }
        self.kiloEnabledOrganizationIDs = current
    }
}

/// Small order-preserving set used to dedupe enabled IDs without sorting.
private struct KiloOrgIDLinkedHashSet<Element: Hashable>: Sequence {
    private var seen: Set<Element> = []
    private var ordered: [Element] = []

    init(_ sequence: some Sequence<Element>) {
        for element in sequence where self.seen.insert(element).inserted {
            self.ordered.append(element)
        }
    }

    func makeIterator() -> IndexingIterator<[Element]> {
        self.ordered.makeIterator()
    }
}
