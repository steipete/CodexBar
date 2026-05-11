import CodexBarCore
import Foundation

struct KiloScopeSnapshot: Identifiable, Equatable {
    let id: String // KiloUsageScope.scopeIdentifier
    let scope: KiloUsageScope
    let snapshot: UsageSnapshot?
    let errorMessage: String?
    let sourceLabel: String?

    static func == (lhs: KiloScopeSnapshot, rhs: KiloScopeSnapshot) -> Bool {
        lhs.id == rhs.id
            && lhs.snapshot?.updatedAt == rhs.snapshot?.updatedAt
            && lhs.errorMessage == rhs.errorMessage
            && lhs.sourceLabel == rhs.sourceLabel
    }
}

extension UsageStore {
    var kiloEnabledScopes: [KiloUsageScope] {
        var scopes: [KiloUsageScope] = [.personal]
        let enabled = self.settings.kiloEnabledOrganizationIDs
        guard !enabled.isEmpty else { return scopes }
        let knownByID = Dictionary(
            uniqueKeysWithValues: self.settings.kiloKnownOrganizations.map { ($0.id, $0) })
        for id in enabled {
            if let org = knownByID[id] {
                scopes.append(.organization(id: org.id, name: org.name))
            }
        }
        return scopes
    }

    func shouldFanOutKiloScopes() -> Bool {
        self.kiloEnabledScopes.count > 1
    }

    func refreshKiloScopes() async {
        let scopes = self.kiloEnabledScopes
        guard scopes.count > 1 else {
            await MainActor.run { self.kiloScopeSnapshots = [] }
            return
        }
        let apiKey = self.settings.configSnapshot.providerConfig(for: .kilo)?.sanitizedAPIKey
            ?? ProcessInfo.processInfo.environment[KiloSettingsReader.apiTokenKey]
        guard let resolvedKey = apiKey, !resolvedKey.isEmpty else {
            await MainActor.run {
                self.kiloScopeSnapshots = scopes.map {
                    KiloScopeSnapshot(
                        id: $0.scopeIdentifier,
                        scope: $0,
                        snapshot: nil,
                        errorMessage: "Kilo API credentials missing.",
                        sourceLabel: nil)
                }
            }
            return
        }

        let env = ProcessInfo.processInfo.environment
        let results: [KiloScopeSnapshot] = await withTaskGroup(of: KiloScopeSnapshot.self) { group in
            for scope in scopes {
                group.addTask {
                    do {
                        let raw = try await KiloUsageFetcher.fetchUsage(
                            apiKey: resolvedKey,
                            scope: scope,
                            environment: env)
                        let snapshot = raw.toUsageSnapshot()
                            .withAccountOrganization(scope.displayName)
                        return KiloScopeSnapshot(
                            id: scope.scopeIdentifier,
                            scope: scope,
                            snapshot: snapshot,
                            errorMessage: nil,
                            sourceLabel: "api")
                    } catch {
                        return KiloScopeSnapshot(
                            id: scope.scopeIdentifier,
                            scope: scope,
                            snapshot: nil,
                            errorMessage: (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription,
                            sourceLabel: nil)
                    }
                }
            }
            var collected: [KiloScopeSnapshot] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let resultByID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        let ordered = scopes.compactMap { resultByID[$0.scopeIdentifier] }

        await MainActor.run {
            self.kiloScopeSnapshots = ordered
        }
    }
}

extension UsageSnapshot {
    fileprivate func withAccountOrganization(_ org: String) -> UsageSnapshot {
        let baseIdentity = self.identity
        let newIdentity = ProviderIdentitySnapshot(
            providerID: baseIdentity?.providerID ?? .kilo,
            accountEmail: baseIdentity?.accountEmail,
            accountOrganization: org,
            loginMethod: baseIdentity?.loginMethod)
        return UsageSnapshot(
            primary: self.primary,
            secondary: self.secondary,
            tertiary: self.tertiary,
            extraRateWindows: self.extraRateWindows,
            providerCost: self.providerCost,
            zaiUsage: self.zaiUsage,
            minimaxUsage: self.minimaxUsage,
            openRouterUsage: self.openRouterUsage,
            cursorRequests: self.cursorRequests,
            updatedAt: self.updatedAt,
            identity: newIdentity)
    }
}
