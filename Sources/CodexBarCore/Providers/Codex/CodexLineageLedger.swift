import Foundation

/// Experimental accounting model for Codex rollout families.
///
/// Rollout files are overlapping physical views of a logical lineage. The ledger builds the
/// transitive lineage first, then admits each complete token observation once per lineage.
/// It intentionally does not participate in production cost totals yet.
enum CodexLineageLedger {
    struct Totals: Equatable, Hashable, Sendable {
        var input: Int
        var cached: Int
        var output: Int

        static let zero = Self(input: 0, cached: 0, output: 0)

        mutating func add(_ other: Self) {
            self.input += other.input
            self.cached += other.cached
            self.output += other.output
        }
    }

    struct Observation: Equatable, Sendable {
        let eventID: String?
        let timestamp: String
        let last: Totals
        let total: Totals

        init(eventID: String? = nil, timestamp: String, last: Totals, total: Totals) {
            self.eventID = eventID
            self.timestamp = timestamp
            self.last = last
            self.total = total
        }
    }

    struct Document: Equatable, Sendable {
        /// Canonical owner from the rollout filename when available.
        let ownerID: String
        /// Session identity persisted in metadata. Fork copies may retain an ancestor identity.
        let metadataSessionID: String?
        let parentSessionID: String?
        let observations: [Observation]
    }

    struct Report: Equatable, Sendable {
        let utcDays: [String: Totals]
        let localDays: [String: Totals]
        let componentCount: Int
        let acceptedObservationCount: Int
        let duplicateObservationCount: Int
    }

    enum LedgerError: Error, Equatable {
        case emptyOwnerID
        case invalidTimestamp(String)
    }

    static func reconcile(documents: [Document], localTimeZone: TimeZone) throws -> Report {
        var graph = DisjointSet()
        for document in documents {
            guard !document.ownerID.isEmpty else { throw LedgerError.emptyOwnerID }
            graph.insert(document.ownerID)
            if let metadataSessionID = Self.nonEmpty(document.metadataSessionID) {
                graph.union(document.ownerID, metadataSessionID)
            }
            if let parentSessionID = Self.nonEmpty(document.parentSessionID) {
                graph.union(document.ownerID, parentSessionID)
            }
        }

        var acceptedByComponent: [String: [ObservationIdentity: AcceptedObservation]] = [:]
        var acceptedFingerprintByComponentOwner: [String: [String: [Fingerprint: ObservationIdentity]]] = [:]
        var physicalObservationCount = 0
        for document in documents {
            let componentID = graph.find(document.ownerID)
            var accepted = acceptedByComponent[componentID] ?? [:]
            var acceptedFingerprintByOwner = acceptedFingerprintByComponentOwner[componentID] ?? [:]
            for observation in document.observations {
                physicalObservationCount += 1
                let date = try Self.date(from: observation.timestamp)
                let fingerprint = Fingerprint(last: observation.last, total: observation.total)
                let proposedIdentity = ObservationIdentity(
                    eventID: Self.nonEmpty(observation.eventID),
                    fingerprint: fingerprint)
                let identity = accepted[proposedIdentity] == nil
                    ? acceptedFingerprintByOwner[document.ownerID]?[fingerprint] ?? proposedIdentity
                    : proposedIdentity
                if let existing = accepted[identity], existing.date <= date {
                    continue
                }
                accepted[identity] = AcceptedObservation(date: date, last: observation.last)
                if identity == proposedIdentity {
                    acceptedFingerprintByOwner[document.ownerID, default: [:]][fingerprint] = identity
                }
            }
            acceptedByComponent[componentID] = accepted
            acceptedFingerprintByComponentOwner[componentID] = acceptedFingerprintByOwner
        }

        var utcDays: [String: Totals] = [:]
        var localDays: [String: Totals] = [:]
        var acceptedObservationCount = 0
        for accepted in acceptedByComponent.values {
            acceptedObservationCount += accepted.count
            for observation in accepted.values {
                Self.add(observation.last, on: observation.date, timeZone: .gmt, to: &utcDays)
                Self.add(observation.last, on: observation.date, timeZone: localTimeZone, to: &localDays)
            }
        }

        return Report(
            utcDays: utcDays,
            localDays: localDays,
            componentCount: Set(documents.map { graph.find($0.ownerID) }).count,
            acceptedObservationCount: acceptedObservationCount,
            duplicateObservationCount: physicalObservationCount - acceptedObservationCount)
    }

    private struct Fingerprint: Equatable, Hashable {
        let last: Totals
        let total: Totals
    }

    private enum ObservationIdentity: Equatable, Hashable {
        case event(String, Fingerprint)
        case fingerprint(Fingerprint)

        init(eventID: String?, fingerprint: Fingerprint) {
            self = eventID.map { .event($0, fingerprint) } ?? .fingerprint(fingerprint)
        }
    }

    private struct AcceptedObservation {
        let date: Date
        let last: Totals
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func date(from timestamp: String) throws -> Date {
        guard let date = CostUsageScanner.dateFromTimestamp(timestamp) else {
            throw LedgerError.invalidTimestamp(timestamp)
        }
        return date
    }

    private static func add(
        _ totals: Totals,
        on date: Date,
        timeZone: TimeZone,
        to days: inout [String: Totals])
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return }
        let key = String(format: "%04d-%02d-%02d", year, month, day)
        var dayTotals = days[key] ?? .zero
        dayTotals.add(totals)
        days[key] = dayTotals
    }

    private struct DisjointSet {
        private var parents: [String: String] = [:]

        mutating func insert(_ item: String) {
            if self.parents[item] == nil {
                self.parents[item] = item
            }
        }

        mutating func find(_ item: String) -> String {
            self.insert(item)
            guard let parent = self.parents[item], parent != item else { return item }
            let root = self.find(parent)
            self.parents[item] = root
            return root
        }

        mutating func union(_ first: String, _ second: String) {
            let firstRoot = self.find(first)
            let secondRoot = self.find(second)
            if firstRoot != secondRoot {
                self.parents[secondRoot] = firstRoot
            }
        }
    }
}
