import CodexBarCore
import Foundation

enum SessionEquivalentWindowPairResolution {
    case resolved(
        session: RateWindow,
        weekly: RateWindow,
        weeklyWindowID: String?,
        historyIdentity: String)
    case incomplete
    case ambiguous

    var isAmbiguous: Bool {
        if case .ambiguous = self {
            return true
        }
        return false
    }
}

struct SessionEquivalentWindowComponent {
    let window: RateWindow
    let namedID: String?
    let historyIdentity: String
}

extension UsageStore {
    nonisolated static let legacySessionEquivalentHistoryIdentityDefaultsKey =
        "SessionEquivalentHistoryWindowPairsV2"
    private nonisolated static let unresolvedSessionEquivalentComponentIdentity = "__unresolved__"

    func planUtilizationWeeklyWindow(provider: UsageProvider, snapshot: UsageSnapshot) -> RateWindow? {
        if provider == .antigravity {
            let namedWeeklyWindows = snapshot.extraRateWindows?
                .filter {
                    $0.usageKnown
                        && $0.id.hasPrefix("antigravity-quota-summary-")
                        && $0.window.windowMinutes == Self.weeklyWindowMinutes
                }
                .map(\.window) ?? []
            if let mostUsedWeeklyWindow = namedWeeklyWindows.max(by: { $0.usedPercent < $1.usedPercent }) {
                return mostUsedWeeklyWindow
            }

            let legacyWeeklyWindows = [snapshot.primary, snapshot.secondary, snapshot.tertiary]
                .compactMap(\.self)
                .filter { $0.windowMinutes == Self.weeklyWindowMinutes }
                + (snapshot.extraRateWindows?
                    .filter { $0.usageKnown && $0.window.windowMinutes == Self.weeklyWindowMinutes }
                    .map(\.window) ?? [])
            return legacyWeeklyWindows.max(by: { $0.usedPercent < $1.usedPercent })
        }

        let standardWeeklyWindow = [snapshot.primary, snapshot.secondary, snapshot.tertiary]
            .compactMap(\.self)
            .first { $0.windowMinutes == Self.weeklyWindowMinutes }
        let extraWeeklyWindow = snapshot.extraRateWindows?
            .lazy
            .first { $0.usageKnown && $0.window.windowMinutes == Self.weeklyWindowMinutes }?
            .window
        return standardWeeklyWindow ?? extraWeeklyWindow
    }

    func sessionEquivalentWindows(provider: UsageProvider, snapshot: UsageSnapshot)
        -> (session: RateWindow, weekly: RateWindow, weeklyWindowID: String?, historyIdentity: String?)?
    {
        if provider == .antigravity {
            return Self.antigravitySessionEquivalentWindows(snapshot: snapshot)
        }
        if provider == .claude {
            guard let session = snapshot.primary,
                  session.windowMinutes.map({ PlanUtilizationSeriesName.session.canonicalWindowMinutes($0) })
                  == Self.sessionWindowMinutes,
                  let weekly = snapshot.secondary,
                  weekly.windowMinutes.map({ PlanUtilizationSeriesName.weekly.canonicalWindowMinutes($0) })
                  == Self.weeklyWindowMinutes
            else {
                return nil
            }
            return (session, weekly, nil, nil)
        }
        guard case let .resolved(session, weekly, weeklyWindowID, historyIdentity) =
            Self.genericSessionEquivalentWindowPairResolution(snapshot: snapshot)
        else {
            return nil
        }
        return (session, weekly, weeklyWindowID, historyIdentity)
    }

    nonisolated static func genericSessionEquivalentWindowPairResolution(snapshot: UsageSnapshot)
        -> SessionEquivalentWindowPairResolution
    {
        let session = Self.sessionEquivalentWindowResolution(
            snapshot: snapshot,
            windowMinutes: Self.sessionWindowMinutes)
        let weekly = Self.sessionEquivalentWindowResolution(
            snapshot: snapshot,
            windowMinutes: Self.weeklyWindowMinutes)
        if session.isAmbiguous || weekly.isAmbiguous {
            return .ambiguous
        }
        guard case let .resolved(sessionWindow, _, sessionIdentity) = session,
              case let .resolved(weeklyWindow, weeklyNamedID, weeklyIdentity) = weekly
        else {
            return .incomplete
        }
        guard Self.hasCanonicalSessionEquivalentRelationship(
            sessionIdentity: sessionIdentity,
            weeklyIdentity: weeklyIdentity)
        else {
            return .ambiguous
        }
        return .resolved(
            session: sessionWindow,
            weekly: weeklyWindow,
            weeklyWindowID: weeklyNamedID,
            historyIdentity: Self.sessionEquivalentPairIdentity(
                session: sessionIdentity,
                weekly: weeklyIdentity))
    }

    nonisolated static func genericSessionEquivalentWindowComponents(snapshot: UsageSnapshot)
        -> (session: SessionEquivalentWindowComponent?, weekly: SessionEquivalentWindowComponent?)
    {
        func component(_ resolution: SessionEquivalentWindowResolution) -> SessionEquivalentWindowComponent? {
            guard case let .resolved(window, namedID, identity) = resolution else { return nil }
            return SessionEquivalentWindowComponent(window: window, namedID: namedID, historyIdentity: identity)
        }

        return (
            session: component(Self.sessionEquivalentWindowResolution(
                snapshot: snapshot,
                windowMinutes: Self.sessionWindowMinutes)),
            weekly: component(Self.sessionEquivalentWindowResolution(
                snapshot: snapshot,
                windowMinutes: Self.weeklyWindowMinutes)))
    }

    nonisolated static func sessionEquivalentPairComponents(from identity: String)
        -> (session: String, weekly: String)?
    {
        let bytes = Array(identity.utf8)
        var offset = 0

        func parseComponent() -> String? {
            let lengthStart = offset
            while offset < bytes.count, bytes[offset] >= 48, bytes[offset] <= 57 {
                offset += 1
            }
            guard offset > lengthStart,
                  offset < bytes.count,
                  bytes[offset] == 35,
                  let lengthText = String(bytes: bytes[lengthStart..<offset], encoding: .utf8),
                  let length = Int(lengthText)
            else {
                return nil
            }
            offset += 1
            guard length >= 0, length <= bytes.count - offset else { return nil }
            let endOffset = offset + length
            let componentBytes = bytes[offset..<endOffset]
            offset = endOffset
            return String(bytes: componentBytes, encoding: .utf8)
        }

        guard let session = parseComponent(),
              let weekly = parseComponent(),
              offset == bytes.count
        else {
            return nil
        }
        return (session, weekly)
    }

    func sessionEquivalentHistoryIdentityMatches(
        provider: UsageProvider,
        accountKey: String?,
        historyIdentity: String?) -> Bool
    {
        guard ![UsageProvider.codex, .claude, .antigravity].contains(provider) else { return true }
        guard let historyIdentity else { return false }
        let persistedIdentity = self.planUtilizationHistory[provider]?
            .sessionEquivalentWindowPairIdentity(for: accountKey)
        return (persistedIdentity ?? self.legacySessionEquivalentHistoryIdentity(
            provider: provider,
            accountKey: accountKey)) == historyIdentity
    }

    func legacySessionEquivalentHistoryIdentity(provider: UsageProvider, accountKey: String?) -> String? {
        let identityKey = "\(provider.rawValue)|\(accountKey ?? Self.planUtilizationUnscopedPreferredKey)"
        let identities = self.settings.userDefaults.dictionary(
            forKey: Self.legacySessionEquivalentHistoryIdentityDefaultsKey) as? [String: String]
        return identities?[identityKey]
    }

    func reconcileGenericSessionEquivalentHistory(
        scope: (provider: UsageProvider, accountKey: String?),
        snapshot: UsageSnapshot,
        providerBuckets: inout PlanUtilizationHistoryBuckets,
        histories: inout [PlanUtilizationSeriesHistory],
        samples: inout [PlanUtilizationSeriesSample])
    {
        var previousIdentity = self.genericSessionEquivalentPreviousIdentity(
            provider: scope.provider,
            accountKey: scope.accountKey,
            providerBuckets: &providerBuckets)
        switch Self.genericSessionEquivalentWindowPairResolution(snapshot: snapshot) {
        case let .resolved(_, _, _, resolvedIdentity):
            Self.reconcileResolvedGenericSessionEquivalentIdentity(
                previousIdentity: previousIdentity,
                resolvedIdentity: resolvedIdentity,
                accountKey: scope.accountKey,
                providerBuckets: &providerBuckets,
                histories: &histories)
        case .incomplete:
            let currentWeeklyIdentity = Self.genericSessionEquivalentWindowComponents(snapshot: snapshot)
                .weekly?.historyIdentity
            if previousIdentity == nil, let currentWeeklyIdentity {
                previousIdentity = Self.sessionEquivalentPairIdentity(
                    session: Self.unresolvedSessionEquivalentComponentIdentity,
                    weekly: currentWeeklyIdentity)
                providerBuckets.setSessionEquivalentWindowPairIdentity(previousIdentity, for: scope.accountKey)
            }
            let previousComponents = previousIdentity.flatMap(Self.sessionEquivalentPairComponents(from:))
            if previousComponents?.session == Self.unresolvedSessionEquivalentComponentIdentity,
               previousComponents?.weekly == currentWeeklyIdentity
            {
                samples.removeAll { $0.name == .session }
            } else if previousIdentity != nil {
                samples.removeAll { $0.name == .session || $0.name == .weekly }
            }
        case .ambiguous:
            let currentWeeklyIdentity = Self.genericSessionEquivalentWindowComponents(snapshot: snapshot)
                .weekly?.historyIdentity
            if previousIdentity == nil, let currentWeeklyIdentity {
                previousIdentity = Self.sessionEquivalentPairIdentity(
                    session: Self.unresolvedSessionEquivalentComponentIdentity,
                    weekly: currentWeeklyIdentity)
                providerBuckets.setSessionEquivalentWindowPairIdentity(previousIdentity, for: scope.accountKey)
            }
            Self.reconcileAmbiguousGenericSessionEquivalentSamples(
                previousIdentity: previousIdentity,
                snapshot: snapshot,
                samples: &samples)
        }
    }

    private func genericSessionEquivalentPreviousIdentity(
        provider: UsageProvider,
        accountKey: String?,
        providerBuckets: inout PlanUtilizationHistoryBuckets) -> String?
    {
        let persistedIdentity = providerBuckets.sessionEquivalentWindowPairIdentity(for: accountKey)
        let previousIdentity = persistedIdentity ?? self.legacySessionEquivalentHistoryIdentity(
            provider: provider,
            accountKey: accountKey)
        if persistedIdentity == nil, let previousIdentity {
            providerBuckets.setSessionEquivalentWindowPairIdentity(previousIdentity, for: accountKey)
        }
        return previousIdentity
    }

    private nonisolated static func reconcileResolvedGenericSessionEquivalentIdentity(
        previousIdentity: String?,
        resolvedIdentity: String,
        accountKey: String?,
        providerBuckets: inout PlanUtilizationHistoryBuckets,
        histories: inout [PlanUtilizationSeriesHistory])
    {
        guard previousIdentity != resolvedIdentity else { return }
        if let previousIdentity,
           let previousComponents = sessionEquivalentPairComponents(from: previousIdentity),
           let resolvedComponents = sessionEquivalentPairComponents(from: resolvedIdentity)
        {
            histories.removeAll {
                ($0.name == .session && previousComponents.session != resolvedComponents.session)
                    || ($0.name == .weekly && previousComponents.weekly != resolvedComponents.weekly)
            }
        } else if previousIdentity != nil {
            histories.removeAll { $0.name == .session || $0.name == .weekly }
        } else {
            histories.removeAll { $0.name == .session }
        }
        providerBuckets.setSessionEquivalentWindowPairIdentity(resolvedIdentity, for: accountKey)
    }

    private nonisolated static func reconcileAmbiguousGenericSessionEquivalentSamples(
        previousIdentity: String?,
        snapshot: UsageSnapshot,
        samples: inout [PlanUtilizationSeriesSample])
    {
        let currentWeeklyIdentity = Self.genericSessionEquivalentWindowComponents(snapshot: snapshot)
            .weekly?.historyIdentity
        let previousWeeklyIdentity = previousIdentity.flatMap {
            Self.sessionEquivalentPairComponents(from: $0)?.weekly
        }
        samples.removeAll { sample in
            if sample.name == .session {
                return true
            }
            if sample.name == .weekly, previousIdentity != nil {
                return previousWeeklyIdentity == nil || previousWeeklyIdentity != currentWeeklyIdentity
            }
            return false
        }
    }

    func planUtilizationSessionWindow(provider: UsageProvider, snapshot: UsageSnapshot) -> RateWindow? {
        let standardSessionWindow = [snapshot.primary, snapshot.secondary, snapshot.tertiary]
            .compactMap(\.self)
            .first { $0.windowMinutes == Self.sessionWindowMinutes }
        let extraSessionWindow = snapshot.extraRateWindows?
            .lazy
            .first { $0.usageKnown && $0.window.windowMinutes == Self.sessionWindowMinutes }?
            .window
        return standardSessionWindow
            ?? self.sessionQuotaWindow(provider: provider, snapshot: snapshot)?.window
            ?? extraSessionWindow
    }

    private nonisolated static func antigravitySessionEquivalentWindows(snapshot: UsageSnapshot)
        -> (session: RateWindow, weekly: RateWindow, weeklyWindowID: String?, historyIdentity: String?)?
    {
        let namedWindows = snapshot.extraRateWindows?
            .filter { $0.usageKnown && $0.id.hasPrefix("antigravity-quota-summary-") } ?? []
        let grouped = Dictionary(grouping: namedWindows) { window in
            Self.antigravityQuotaFamilyKey(window.id)
        }
        let completeGeminiFamilies: [(session: NamedRateWindow, weekly: NamedRateWindow)] = grouped.keys
            .filter { $0 == "gemini" }.compactMap { family in
                guard let windows = grouped[family] else { return nil }
                let sessions = windows.filter { $0.window.windowMinutes == Self.sessionWindowMinutes }
                let weeklies = windows.filter { $0.window.windowMinutes == Self.weeklyWindowMinutes }
                guard sessions.count == 1, weeklies.count == 1 else { return nil }
                return (session: sessions[0], weekly: weeklies[0])
            }
        guard completeGeminiFamilies.count == 1, let pair = completeGeminiFamilies.first else { return nil }
        return (pair.session.window, pair.weekly.window, pair.weekly.id, nil)
    }

    private enum SessionEquivalentWindowResolution {
        case resolved(window: RateWindow, namedID: String?, identity: String)
        case incomplete
        case ambiguous

        var isAmbiguous: Bool {
            if case .ambiguous = self {
                return true
            }
            return false
        }
    }

    private nonisolated static func sessionEquivalentWindowResolution(
        snapshot: UsageSnapshot,
        windowMinutes: Int) -> SessionEquivalentWindowResolution
    {
        let standardCandidates: [(window: RateWindow, identity: String)] = [
            snapshot.primary.map { ($0, "standard:primary") },
            snapshot.secondary.map { ($0, "standard:secondary") },
            snapshot.tertiary.map { ($0, "standard:tertiary") },
        ].compactMap(\.self).filter { $0.window.windowMinutes == windowMinutes }
        if standardCandidates.count == 1, let candidate = standardCandidates.first {
            return .resolved(window: candidate.window, namedID: nil, identity: candidate.identity)
        }
        guard standardCandidates.isEmpty else { return .ambiguous }

        let namedCandidates = snapshot.extraRateWindows?.filter {
            $0.window.windowMinutes == windowMinutes
        } ?? []
        guard namedCandidates.count <= 1 else { return .ambiguous }
        guard let candidate = namedCandidates.first, candidate.usageKnown else { return .incomplete }
        return .resolved(window: candidate.window, namedID: candidate.id, identity: "named:\(candidate.id)")
    }

    private nonisolated static func sessionEquivalentPairIdentity(session: String, weekly: String) -> String {
        "\(session.utf8.count)#\(session)\(weekly.utf8.count)#\(weekly)"
    }

    private nonisolated static func hasCanonicalSessionEquivalentRelationship(
        sessionIdentity: String,
        weeklyIdentity: String) -> Bool
    {
        if sessionIdentity.hasPrefix("standard:"), weeklyIdentity.hasPrefix("standard:") {
            return true
        }
        guard sessionIdentity.hasPrefix("named:"), weeklyIdentity.hasPrefix("named:") else { return false }
        let sessionID = String(sessionIdentity.dropFirst("named:".count))
        let weeklyID = String(weeklyIdentity.dropFirst("named:".count))
        guard let sessionFamily = Self.sessionEquivalentFamily(
            id: sessionID,
            suffixes: ["-session", "_session", " session", "-5h", "_5h", " 5h"]),
            let weeklyFamily = Self.sessionEquivalentFamily(
                id: weeklyID,
                suffixes: ["-weekly", "_weekly", " weekly"])
        else {
            return false
        }
        return sessionFamily == weeklyFamily
    }

    private nonisolated static func sessionEquivalentFamily(id: String, suffixes: [String]) -> String? {
        let normalized = id.lowercased()
        guard let suffix = suffixes.first(where: { normalized.hasSuffix($0) }) else { return nil }
        let family = normalized.dropLast(suffix.count)
        return family.isEmpty ? nil : String(family)
    }

    private nonisolated static func antigravityQuotaFamilyKey(_ id: String) -> String {
        var key = String(id.dropFirst("antigravity-quota-summary-".count)).lowercased()
        let suffixes = [
            "-5h limit", "_5h_limit", "-weekly", "_weekly", " weekly",
            "-session", "_session", " session", "-5h", "_5h", " 5h",
        ]
        if let suffix = suffixes.first(where: { key.hasSuffix($0) }) {
            key.removeLast(suffix.count)
        } else if ["weekly", "session", "5h"].contains(key) {
            key = ""
        }
        return key
    }
}
