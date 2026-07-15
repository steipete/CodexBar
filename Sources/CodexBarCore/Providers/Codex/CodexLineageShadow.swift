import Foundation

/// Privacy-safe comparison between the production file scanner and the experimental lineage ledger.
enum CodexLineageShadow {
    struct DayDifference: Equatable, Sendable {
        let day: String
        let legacy: CodexLineageLedger.Totals
        let ledger: CodexLineageLedger.Totals

        var delta: CodexLineageLedger.Totals {
            .init(
                input: self.ledger.input - self.legacy.input,
                cached: self.ledger.cached - self.legacy.cached,
                output: self.ledger.output - self.legacy.output)
        }
    }

    struct Report: Equatable, Sendable {
        let days: [DayDifference]
        let acceptedObservationCount: Int
        let duplicateObservationCount: Int
        let componentCount: Int
        let referencedParentDocumentCount: Int
        let unresolvedParentCount: Int
        let rejectedObservationCount: Int
        let primaryFamilyCount: Int
        let incompleteProvenanceFamilyCount: Int
        let containedFamilyCount: Int
        let containmentReasonCounts: [CodexLineageLedger.ContainmentReason: Int]
    }

    static func run(
        includedFiles: [URL],
        roots: [URL],
        legacyDays: [String: [String: [Int]]],
        dayRange: ClosedRange<String>,
        localTimeZone: TimeZone,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> Report
    {
        let discovery = try CodexLineageDiscovery.discover(
            includedFiles: includedFiles,
            roots: roots,
            checkCancellation: checkCancellation)
        var rejectedObservationCount = 0
        var documents: [CodexLineageLedger.Document] = []
        documents.reserveCapacity(discovery.documents.count)
        for document in discovery.documents {
            try checkCancellation?()
            for observation in document.observations {
                try checkCancellation?()
                let accepted = CostUsageScanner.dateFromTimestamp(observation.timestamp) != nil
                if !accepted {
                    rejectedObservationCount += 1
                }
            }
            documents.append(CodexLineageLedger.Document(
                ownerID: document.ownerID,
                metadataSessionID: document.metadataSessionID,
                parentSessionID: document.parentSessionID,
                observations: document.observations,
                scopeID: document.scopeID,
                incompleteObservationCount: document.incompleteObservationCount))
        }
        let conservative = try CodexLineageLedger.reconcileConservatively(
            documents: documents,
            unresolvedParents: discovery.unresolvedParents,
            localTimeZone: localTimeZone,
            checkCancellation: checkCancellation)
        let ledger = conservative.primary
        let legacy = Self.legacyTotalsByDay(legacyDays)
        let dayKeys = Set(legacy.keys).union(ledger.localDays.keys)
            .filter(dayRange.contains)
            .sorted()
        let days = dayKeys.map { day in
            DayDifference(day: day, legacy: legacy[day] ?? .zero, ledger: ledger.localDays[day] ?? .zero)
        }
        return Report(
            days: days,
            acceptedObservationCount: ledger.acceptedObservationCount,
            duplicateObservationCount: ledger.duplicateObservationCount,
            componentCount: ledger.componentCount,
            referencedParentDocumentCount: discovery.referencedParentDocumentCount,
            unresolvedParentCount: discovery.unresolvedParents.count,
            rejectedObservationCount: rejectedObservationCount,
            primaryFamilyCount: conservative.families.count { $0.quality == .primary },
            incompleteProvenanceFamilyCount: conservative.families.count {
                $0.quality == .incompleteProvenance
            },
            containedFamilyCount: conservative.families.count {
                if case .contained = $0.quality {
                    return true
                }
                return false
            },
            containmentReasonCounts: Self.containmentReasonCounts(conservative.families))
    }

    private static func containmentReasonCounts(
        _ families: [CodexLineageLedger.FamilyDisposition]) -> [CodexLineageLedger.ContainmentReason: Int]
    {
        var counts: [CodexLineageLedger.ContainmentReason: Int] = [:]
        for family in families {
            guard case let .contained(reasons) = family.quality else { continue }
            for reason in reasons {
                counts[reason, default: 0] += 1
            }
        }
        return counts
    }

    private static func legacyTotalsByDay(
        _ days: [String: [String: [Int]]]) -> [String: CodexLineageLedger.Totals]
    {
        days.mapValues { models in
            models.values.reduce(into: CodexLineageLedger.Totals.zero) { totals, packed in
                totals.input += packed[safe: 0] ?? 0
                totals.cached += packed[safe: 1] ?? 0
                totals.output += packed[safe: 2] ?? 0
            }
        }
    }
}
