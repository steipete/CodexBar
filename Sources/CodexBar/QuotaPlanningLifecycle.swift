import CodexBarCore
import CryptoKit
import Foundation

struct QuotaPlanningStrategyScope: Hashable {
    let provider: UsageProvider
    let accountDiscriminator: String
    let strategyID: String
    let strategyKind: ProviderFetchKind

    init?(
        provider: UsageProvider,
        accountDiscriminator: String?,
        strategyID: String,
        strategyKind: ProviderFetchKind)
    {
        guard let accountDiscriminator = Self.normalized(accountDiscriminator),
              let strategyID = Self.normalized(strategyID)
        else {
            return nil
        }
        self.provider = provider
        self.accountDiscriminator = accountDiscriminator
        self.strategyID = strategyID
        self.strategyKind = strategyKind
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }
}

struct QuotaPlanningScopeKey: Hashable {
    let strategyScope: QuotaPlanningStrategyScope
    let pairID: String
}

struct QuotaPlanningPublicationState: Equatable {
    let estimate: QuotaPlanningEstimate
    let monotonicExpiresAt: ContinuousClock.Instant
}

struct QuotaPlanningReceipt {
    let wallNow: Date
    let monotonicNow: ContinuousClock.Instant
}

struct QuotaPlanningLifecycle {
    static let presentationTTL: Duration = .seconds(60 * 60)

    private(set) var calibrations: [QuotaPlanningScopeKey: QuotaPlanningCalibrationState] = [:]
    private(set) var activeScopes: [UsageProvider: QuotaPlanningStrategyScope] = [:]
    private(set) var publications: [UsageProvider: [String: QuotaPlanningPublicationState]] = [:]

    mutating func recordSuccessfulFetch(
        provider: UsageProvider,
        accountDiscriminator: String?,
        result: ProviderFetchResult,
        resolvedPairs: [QuotaPlanningPairSnapshot],
        receipt: QuotaPlanningReceipt)
    {
        let wallNow = receipt.wallNow
        let monotonicNow = receipt.monotonicNow
        self.expire(wallNow: wallNow, monotonicNow: monotonicNow)
        guard let scope = QuotaPlanningStrategyScope(
            provider: provider,
            accountDiscriminator: accountDiscriminator,
            strategyID: result.strategyID,
            strategyKind: result.strategyKind)
        else {
            self.activeScopes.removeValue(forKey: provider)
            self.hidePublications(for: provider)
            return
        }

        let scopeChanged = self.activeScopes[provider] != scope
        self.activeScopes[provider] = scope
        if scopeChanged {
            self.hidePublications(for: provider)
        }

        guard result.observationFreshness == .live else {
            return
        }

        self.publications.removeValue(forKey: provider)
        var nextPublications: [String: QuotaPlanningPublicationState] = [:]
        let monotonicExpiresAt = monotonicNow.advanced(by: Self.presentationTTL)

        for pair in resolvedPairs {
            let pairID = pair.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pairID.isEmpty,
                  let observation = QuotaPlanningEstimator.observation(for: pair, now: wallNow)
            else {
                continue
            }

            let key = QuotaPlanningScopeKey(strategyScope: scope, pairID: pairID)
            let calibration = QuotaPlanningCalibrationReducer.reduce(
                state: self.calibrations[key],
                observation: observation)
            self.calibrations[key] = calibration

            guard let estimate = QuotaPlanningEstimator.estimate(
                for: pair,
                calibration: calibration,
                now: wallNow)
            else {
                continue
            }
            nextPublications[estimate.longMetricID] = QuotaPlanningPublicationState(
                estimate: estimate,
                monotonicExpiresAt: monotonicExpiresAt)
        }

        if !nextPublications.isEmpty {
            self.publications[provider] = nextPublications
        }
    }

    @discardableResult
    mutating func activateAccount(
        provider: UsageProvider,
        accountDiscriminator: String?) -> Bool
    {
        guard let current = self.activeScopes[provider],
              current.accountDiscriminator != accountDiscriminator?
                  .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }
        self.activeScopes.removeValue(forKey: provider)
        return self.hidePublications(for: provider)
    }

    mutating func expire(
        wallNow: Date,
        monotonicNow: ContinuousClock.Instant)
    {
        for provider in Array(self.publications.keys) {
            guard let providerPublications = self.publications[provider] else { continue }
            let active = providerPublications.filter { _, publication in
                publication.monotonicExpiresAt > monotonicNow &&
                    publication.estimate.shortResetAt > wallNow &&
                    publication.estimate.longResetAt > wallNow
            }
            if active != providerPublications {
                if active.isEmpty {
                    self.publications.removeValue(forKey: provider)
                } else {
                    self.publications[provider] = active
                }
            }
        }

        let unexpiredCalibrations = self.calibrations.filter { _, calibration in
            calibration.canonicalLongResetAt > wallNow
        }
        if unexpiredCalibrations.count != self.calibrations.count {
            self.calibrations = unexpiredCalibrations
        }
    }

    func estimatesByProvider() -> [UsageProvider: [String: QuotaPlanningEstimate]] {
        self.publications.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value.mapValues(\.estimate)
        }
    }

    func nextExpiryDelay(
        wallNow: Date,
        monotonicNow: ContinuousClock.Instant) -> Duration?
    {
        self.publications.values
            .flatMap(\.values)
            .flatMap { publication in
                [
                    monotonicNow.duration(to: publication.monotonicExpiresAt),
                    .seconds(publication.estimate.shortResetAt.timeIntervalSince(wallNow)),
                    .seconds(publication.estimate.longResetAt.timeIntervalSince(wallNow)),
                ]
            }
            .map { max(.zero, $0) }
            .min()
    }

    @discardableResult
    private mutating func hidePublications(for provider: UsageProvider) -> Bool {
        self.publications.removeValue(forKey: provider) != nil
    }
}

@MainActor
extension UsageStore {
    func quotaPlanningEstimate(
        provider: UsageProvider,
        longMetricID: String) -> QuotaPlanningEstimate?
    {
        self.quotaPlanningEstimates[provider]?[longMetricID]
    }

    func recordQuotaPlanningSuccess(
        provider: UsageProvider,
        result: ProviderFetchResult,
        accountDiscriminator: String?)
    {
        guard let capability = ProviderDescriptorRegistry.descriptor(for: provider).quotaPlanning else {
            return
        }
        let wallNow = Date()
        let monotonicNow = self.quotaPlanningClock.now
        self.quotaPlanningLifecycle.recordSuccessfulFetch(
            provider: provider,
            accountDiscriminator: accountDiscriminator,
            result: result,
            resolvedPairs: capability.resolvePairs(for: result),
            receipt: QuotaPlanningReceipt(
                wallNow: wallNow,
                monotonicNow: monotonicNow))
        self.publishQuotaPlanningState()
        self.rescheduleQuotaPlanningExpiry(wallNow: wallNow, monotonicNow: monotonicNow)
    }

    func activateQuotaPlanningAccount(
        provider: UsageProvider,
        accountDiscriminator: String?)
    {
        guard ProviderDescriptorRegistry.descriptor(for: provider).quotaPlanning != nil else { return }
        guard self.quotaPlanningLifecycle.activateAccount(
            provider: provider,
            accountDiscriminator: accountDiscriminator)
        else {
            return
        }
        self.publishQuotaPlanningState()
        self.rescheduleQuotaPlanningExpiry()
    }

    func activateQuotaPlanningTokenAccount(_ provider: UsageProvider, accountID: UUID) {
        self.activateQuotaPlanningAccount(
            provider: provider,
            accountDiscriminator: "token-account:\(accountID.uuidString.lowercased())")
    }

    func activateQuotaPlanningCodexOwner(_ ownerKey: CodexSessionQuotaOwnerKey?) {
        self.activateQuotaPlanningAccount(
            provider: .codex,
            accountDiscriminator: ownerKey?.rawValue)
    }

    func recordQuotaPlanningTokenAccountSuccess(
        _ provider: UsageProvider,
        result: ProviderFetchResult,
        account: ProviderTokenAccount?)
    {
        self.recordQuotaPlanningSuccess(
            provider: provider,
            result: result,
            accountDiscriminator: Self.warningTokenAccountDiscriminator(account)
                ?? Self.quotaPlanningIdentityDiscriminator(provider: provider, usage: result.usage))
    }

    func recordQuotaPlanningCodexSuccess(
        result: ProviderFetchResult,
        ownerKey: CodexSessionQuotaOwnerKey?)
    {
        self.recordQuotaPlanningSuccess(
            provider: .codex,
            result: result,
            accountDiscriminator: ownerKey?.rawValue)
    }

    func handleQuotaPlanningTimeEnvironmentChange() {
        let wallNow = Date()
        let monotonicNow = self.quotaPlanningClock.now
        self.quotaPlanningLifecycle.expire(
            wallNow: wallNow,
            monotonicNow: monotonicNow)
        self.publishQuotaPlanningState()
        self.rescheduleQuotaPlanningExpiry(wallNow: wallNow, monotonicNow: monotonicNow)
    }

    private func publishQuotaPlanningState() {
        let estimates = self.quotaPlanningLifecycle.estimatesByProvider()
        if estimates != self.quotaPlanningEstimates {
            self.quotaPlanningEstimates = estimates
        }
    }

    private func rescheduleQuotaPlanningExpiry(
        wallNow: Date = Date(),
        monotonicNow: ContinuousClock.Instant? = nil)
    {
        self.quotaPlanningExpiryTask?.cancel()
        self.quotaPlanningExpiryGeneration &+= 1
        let generation = self.quotaPlanningExpiryGeneration
        let monotonicNow = monotonicNow ?? self.quotaPlanningClock.now
        guard let delay = self.quotaPlanningLifecycle.nextExpiryDelay(
            wallNow: wallNow,
            monotonicNow: monotonicNow)
        else {
            self.quotaPlanningExpiryTask = nil
            return
        }

        self.quotaPlanningExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, self.quotaPlanningExpiryGeneration == generation else { return }
            self.handleQuotaPlanningTimeEnvironmentChange()
        }
    }

    nonisolated static func quotaPlanningIdentityDiscriminator(
        provider: UsageProvider,
        usage: UsageSnapshot) -> String?
    {
        guard let identity = usage.identity, identity.providerID == provider else { return nil }
        if let accountID = identity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty
        {
            return self.hashedQuotaPlanningIdentity(
                provider: provider,
                kind: "account",
                value: accountID.lowercased())
        }
        guard let email = identity.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !email.isEmpty
        else {
            return nil
        }
        return self.hashedQuotaPlanningIdentity(
            provider: provider,
            kind: "email",
            value: email)
    }

    private nonisolated static func hashedQuotaPlanningIdentity(
        provider: UsageProvider,
        kind: String,
        value: String) -> String
    {
        let input = "quota-planning-owner:v1\0\(provider.rawValue)\0\(kind)\0\(value)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return "provider-identity:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
