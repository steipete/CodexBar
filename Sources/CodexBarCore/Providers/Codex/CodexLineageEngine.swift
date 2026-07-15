#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Pure, in-memory preparation and reuse seam for lineage families.
///
/// Callers retain the previous cache until `publish` succeeds. This keeps cancellation and failed
/// reconciliation from exposing a partially rebuilt set of families.
enum CodexLineageEngine {
    private static let algorithmVersion = 1

    struct Fingerprint: Equatable, Hashable, Sendable {
        let value: String
    }

    struct PreparedFamily: Equatable, Sendable {
        let stableID: String
        let inputFingerprint: Fingerprint
        let documents: [CodexLineageLedger.Document]
        let unresolvedParents: Set<CodexLineageLedger.ParentIdentity>
        let observationCount: Int
    }

    struct PreparedDescriptorFamily: Equatable, Sendable {
        let stableID: String
        let inputFingerprint: Fingerprint
        let descriptors: [CodexLineageTwoPassDiscovery.Descriptor]
        let unresolvedParents: Set<CodexLineageLedger.ParentIdentity>
        let observationCount: Int
    }

    struct FamilyResult: Equatable, Sendable {
        let stableID: String
        let inputFingerprint: Fingerprint
        let familyFingerprint: Fingerprint
        let quality: CodexLineageLedger.FamilyQuality
        let report: CodexLineageLedger.Report
    }

    struct Cache: Equatable, Sendable {
        let algorithmVersion: Int
        let familiesByInputFingerprint: [Fingerprint: FamilyResult]

        static let empty = Self(algorithmVersion: CodexLineageEngine.algorithmVersion, familiesByInputFingerprint: [:])
    }

    struct Diagnostics: Equatable, Sendable {
        let familyCount: Int
        let recomputedFamilyCount: Int
        let reusedFamilyCount: Int
        let observationCount: Int
        let peakFamilyObservationCount: Int
        let peakAcceptedFingerprintCount: Int
        let documentLoadMilliseconds: Int64
        let familyReconciliationMilliseconds: Int64
        let compositionMilliseconds: Int64
    }

    struct Result: Equatable, Sendable {
        let report: CodexLineageLedger.Report
        let families: [FamilyResult]
        let candidateCache: Cache
        let diagnostics: Diagnostics
    }

    static func prepareFamilies(
        documents: [CodexLineageLedger.Document],
        unresolvedParents: Set<CodexLineageLedger.ParentIdentity> = [],
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> [PreparedFamily]
    {
        var graph = DisjointSet()
        for document in documents {
            try checkCancellation?()
            let owner = Self.scoped(document.ownerID, scopeID: document.scopeID)
            graph.insert(owner)
            if let metadata = Self.nonEmpty(document.metadataSessionID) {
                graph.union(owner, Self.scoped(metadata, scopeID: document.scopeID))
            }
            if let parent = Self.nonEmpty(document.parentSessionID) {
                graph.union(owner, Self.scoped(parent, scopeID: document.scopeID))
            }
        }

        var documentsByRoot: [String: [CodexLineageLedger.Document]] = [:]
        for document in documents {
            try checkCancellation?()
            let root = graph.find(Self.scoped(document.ownerID, scopeID: document.scopeID))
            documentsByRoot[root, default: []].append(document)
        }

        var families: [PreparedFamily] = []
        families.reserveCapacity(documentsByRoot.count)
        for familyDocuments in documentsByRoot.values {
            try checkCancellation?()
            var keyedDocuments: [(document: CodexLineageLedger.Document, key: Fingerprint)] = []
            keyedDocuments.reserveCapacity(familyDocuments.count)
            for document in familyDocuments {
                try checkCancellation?()
                try keyedDocuments.append((
                    document: document,
                    key: Self.documentFingerprint(document, checkCancellation: checkCancellation)))
            }
            keyedDocuments.sort { $0.key.value < $1.key.value }
            let sortedDocuments = keyedDocuments.map(\.document)
            let identities = Set(sortedDocuments.flatMap { document in
                [document.ownerID, document.metadataSessionID, document.parentSessionID].compactMap { value in
                    Self.nonEmpty(value).map { Self.scoped($0, scopeID: document.scopeID) }
                }
            })
            let familyUnresolved = unresolvedParents.filter { parent in
                identities.contains(Self.scoped(parent.sessionID, scopeID: parent.scopeID))
            }
            let stableID = identities.min() ?? ""
            let fingerprint = try Self.inputFingerprint(
                documents: sortedDocuments,
                unresolvedParents: familyUnresolved,
                checkCancellation: checkCancellation)
            families.append(PreparedFamily(
                stableID: stableID,
                inputFingerprint: fingerprint,
                documents: sortedDocuments,
                unresolvedParents: familyUnresolved,
                observationCount: sortedDocuments.reduce(0) { $0 + $1.observations.count }))
        }
        return families.sorted { $0.stableID < $1.stableID }
    }

    static func prepareDescriptorFamilies(
        descriptors: [CodexLineageTwoPassDiscovery.Descriptor],
        unresolvedParents: Set<CodexLineageLedger.ParentIdentity> = [],
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> [PreparedDescriptorFamily]
    {
        var graph = DisjointSet()
        for descriptor in descriptors {
            try checkCancellation?()
            let owner = Self.scoped(descriptor.ownerID, scopeID: descriptor.scopeID)
            graph.insert(owner)
            if let metadata = Self.nonEmpty(descriptor.metadataSessionID) {
                graph.union(owner, Self.scoped(metadata, scopeID: descriptor.scopeID))
            }
            if let parent = Self.nonEmpty(descriptor.parentSessionID) {
                graph.union(owner, Self.scoped(parent, scopeID: descriptor.scopeID))
            }
        }
        var descriptorsByRoot: [String: [CodexLineageTwoPassDiscovery.Descriptor]] = [:]
        for descriptor in descriptors {
            try checkCancellation?()
            let root = graph.find(Self.scoped(descriptor.ownerID, scopeID: descriptor.scopeID))
            descriptorsByRoot[root, default: []].append(descriptor)
        }
        var families: [PreparedDescriptorFamily] = []
        for var familyDescriptors in descriptorsByRoot.values {
            try checkCancellation?()
            familyDescriptors.sort { Self.descriptorKey($0) < Self.descriptorKey($1) }
            let identities = Set(familyDescriptors.flatMap { descriptor in
                [descriptor.ownerID, descriptor.metadataSessionID, descriptor.parentSessionID].compactMap { value in
                    Self.nonEmpty(value).map { Self.scoped($0, scopeID: descriptor.scopeID) }
                }
            })
            let familyUnresolved = unresolvedParents.filter {
                identities.contains(Self.scoped($0.sessionID, scopeID: $0.scopeID))
            }
            let fingerprint = Self.descriptorFamilyFingerprint(
                descriptors: familyDescriptors,
                unresolvedParents: familyUnresolved)
            families.append(.init(
                stableID: identities.min() ?? "",
                inputFingerprint: fingerprint,
                descriptors: familyDescriptors,
                unresolvedParents: familyUnresolved,
                observationCount: familyDescriptors.reduce(0) { $0 + $1.observationCount }))
        }
        return families.sorted { $0.stableID < $1.stableID }
    }

    static func reconcileStreaming(
        families: [PreparedDescriptorFamily],
        previousCache: Cache? = nil,
        localTimeZone: TimeZone,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil,
        loadDocument: ((CodexLineageTwoPassDiscovery.Descriptor) throws -> CodexLineageLedger.Document)? = nil) throws
        -> Result
    {
        let reusable = previousCache?.algorithmVersion == Self.algorithmVersion
            ? previousCache?.familiesByInputFingerprint ?? [:]
            : [:]
        var results: [FamilyResult] = []
        var recomputed = 0
        var reused = 0
        var peakLoadedObservations = 0
        var peakAccepted = 0
        var documentLoadDuration = Duration.zero
        var familyReconciliationDuration = Duration.zero
        for family in families.sorted(by: { $0.stableID < $1.stableID }) {
            try checkCancellation?()
            let cacheFingerprint = Self.cacheFingerprint(
                input: family.inputFingerprint,
                localTimeZone: localTimeZone)
            if let cached = reusable[cacheFingerprint], cached.stableID == family.stableID {
                results.append(cached)
                reused += 1
                peakAccepted = max(peakAccepted, cached.report.acceptedObservationCount)
                continue
            }
            var documents: [CodexLineageLedger.Document] = []
            documents.reserveCapacity(family.descriptors.count)
            var loadedObservations = 0
            let loadStarted = ContinuousClock.now
            for descriptor in family.descriptors {
                try checkCancellation?()
                let document: CodexLineageLedger.Document = if let loadDocument {
                    try loadDocument(descriptor)
                } else {
                    try CodexLineageTwoPassDiscovery.loadDocument(
                        descriptor,
                        checkCancellation: checkCancellation)
                }
                loadedObservations += document.observations.count
                documents.append(document)
            }
            documentLoadDuration += loadStarted.duration(to: .now)
            peakLoadedObservations = max(peakLoadedObservations, loadedObservations)
            let reconciliationStarted = ContinuousClock.now
            let conservative = try CodexLineageLedger.reconcileConservatively(
                documents: documents,
                unresolvedParents: family.unresolvedParents,
                localTimeZone: localTimeZone,
                checkCancellation: checkCancellation)
            familyReconciliationDuration += reconciliationStarted.duration(to: .now)
            let quality = conservative.families.first?.quality ?? .primary
            let result = FamilyResult(
                stableID: family.stableID,
                inputFingerprint: family.inputFingerprint,
                familyFingerprint: Self.familyFingerprint(input: cacheFingerprint, quality: quality),
                quality: quality,
                report: conservative.primary)
            results.append(result)
            recomputed += 1
            peakAccepted = max(peakAccepted, result.report.acceptedObservationCount)
        }
        results.sort { $0.stableID < $1.stableID }
        let compositionStarted = ContinuousClock.now
        let report = try Self.compose(results.map(\.report), checkCancellation: checkCancellation)
        let compositionDuration = compositionStarted.duration(to: .now)
        let candidate = Cache(
            algorithmVersion: Self.algorithmVersion,
            familiesByInputFingerprint: Dictionary(uniqueKeysWithValues: results.map {
                (Self.cacheFingerprint(input: $0.inputFingerprint, localTimeZone: localTimeZone), $0)
            }))
        try checkCancellation?()
        return Result(
            report: report,
            families: results,
            candidateCache: candidate,
            diagnostics: .init(
                familyCount: families.count,
                recomputedFamilyCount: recomputed,
                reusedFamilyCount: reused,
                observationCount: families.reduce(0) { $0 + $1.observationCount },
                peakFamilyObservationCount: peakLoadedObservations,
                peakAcceptedFingerprintCount: peakAccepted,
                documentLoadMilliseconds: Self.milliseconds(documentLoadDuration),
                familyReconciliationMilliseconds: Self.milliseconds(familyReconciliationDuration),
                compositionMilliseconds: Self.milliseconds(compositionDuration)))
    }

    static func reconcile(
        families: [PreparedFamily],
        previousCache: Cache? = nil,
        localTimeZone: TimeZone,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> Result
    {
        let reusable = previousCache?.algorithmVersion == Self.algorithmVersion
            ? previousCache?.familiesByInputFingerprint ?? [:]
            : [:]
        var results: [FamilyResult] = []
        results.reserveCapacity(families.count)
        var recomputed = 0
        var reused = 0
        var peakAccepted = 0
        var familyReconciliationDuration = Duration.zero

        for family in families.sorted(by: { $0.stableID < $1.stableID }) {
            try checkCancellation?()
            let cacheFingerprint = Self.cacheFingerprint(
                input: family.inputFingerprint,
                localTimeZone: localTimeZone)
            if let cached = reusable[cacheFingerprint],
               cached.stableID == family.stableID,
               cached.inputFingerprint == family.inputFingerprint
            {
                results.append(cached)
                reused += 1
                peakAccepted = max(peakAccepted, cached.report.acceptedObservationCount)
                continue
            }
            let reconciliationStarted = ContinuousClock.now
            let conservative = try CodexLineageLedger.reconcileConservatively(
                documents: family.documents,
                unresolvedParents: family.unresolvedParents,
                localTimeZone: localTimeZone,
                checkCancellation: checkCancellation)
            familyReconciliationDuration += reconciliationStarted.duration(to: .now)
            let quality = conservative.families.first?.quality ?? .primary
            let familyFingerprint = Self.familyFingerprint(input: cacheFingerprint, quality: quality)
            let result = FamilyResult(
                stableID: family.stableID,
                inputFingerprint: family.inputFingerprint,
                familyFingerprint: familyFingerprint,
                quality: quality,
                report: conservative.primary)
            results.append(result)
            recomputed += 1
            peakAccepted = max(peakAccepted, result.report.acceptedObservationCount)
        }

        results.sort { $0.stableID < $1.stableID }
        let compositionStarted = ContinuousClock.now
        let report = try Self.compose(results.map(\.report), checkCancellation: checkCancellation)
        let compositionDuration = compositionStarted.duration(to: .now)
        let candidate = Cache(
            algorithmVersion: Self.algorithmVersion,
            familiesByInputFingerprint: Dictionary(uniqueKeysWithValues: results.map {
                (Self.cacheFingerprint(input: $0.inputFingerprint, localTimeZone: localTimeZone), $0)
            }))
        try checkCancellation?()
        return Result(
            report: report,
            families: results,
            candidateCache: candidate,
            diagnostics: Diagnostics(
                familyCount: families.count,
                recomputedFamilyCount: recomputed,
                reusedFamilyCount: reused,
                observationCount: families.reduce(0) { $0 + $1.observationCount },
                peakFamilyObservationCount: families.map(\.observationCount).max() ?? 0,
                peakAcceptedFingerprintCount: peakAccepted,
                documentLoadMilliseconds: 0,
                familyReconciliationMilliseconds: Self.milliseconds(familyReconciliationDuration),
                compositionMilliseconds: Self.milliseconds(compositionDuration)))
    }

    static func publish(
        _ candidate: Cache,
        to cache: inout Cache,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws
    {
        try checkCancellation?()
        cache = candidate
    }

    private static func compose(
        _ reports: [CodexLineageLedger.Report],
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> CodexLineageLedger.Report
    {
        var utcDays: [String: CodexLineageLedger.Totals] = [:]
        var localDays: [String: CodexLineageLedger.Totals] = [:]
        var utcRows: [RowKey: RowValue] = [:]
        var localRows: [RowKey: RowValue] = [:]
        for report in reports {
            try checkCancellation?()
            try Self.mergeDays(report.utcDays, into: &utcDays, checkCancellation: checkCancellation)
            try Self.mergeDays(report.localDays, into: &localDays, checkCancellation: checkCancellation)
            try Self.mergeRows(report.utcRows, into: &utcRows, checkCancellation: checkCancellation)
            try Self.mergeRows(report.localRows, into: &localRows, checkCancellation: checkCancellation)
        }
        return CodexLineageLedger.Report(
            utcDays: utcDays,
            localDays: localDays,
            utcRows: Self.rows(utcRows),
            localRows: Self.rows(localRows),
            componentCount: reports.reduce(0) { $0 + $1.componentCount },
            acceptedObservationCount: reports.reduce(0) { $0 + $1.acceptedObservationCount },
            duplicateObservationCount: reports.reduce(0) { $0 + $1.duplicateObservationCount })
    }

    private struct RowKey: Hashable {
        let day: String
        let model: String
    }

    private struct RowValue {
        var totals = CodexLineageLedger.Totals.zero
        var costUSD = 0.0
        var isPriced = true
    }

    private static func mergeDays(
        _ source: [String: CodexLineageLedger.Totals],
        into destination: inout [String: CodexLineageLedger.Totals],
        checkCancellation: CostUsageScanner.CancellationCheck?) throws
    {
        for (day, totals) in source {
            try checkCancellation?()
            var combined = destination[day] ?? .zero
            combined.add(totals)
            destination[day] = combined
        }
    }

    private static func mergeRows(
        _ source: [CodexLineageLedger.DailyRow],
        into destination: inout [RowKey: RowValue],
        checkCancellation: CostUsageScanner.CancellationCheck?) throws
    {
        for row in source {
            try checkCancellation?()
            let key = RowKey(day: row.day, model: row.model)
            var value = destination[key] ?? RowValue()
            value.totals.add(row.totals)
            if let cost = row.costUSD {
                value.costUSD += cost
            } else {
                value.isPriced = false
            }
            destination[key] = value
        }
    }

    private static func rows(_ values: [RowKey: RowValue]) -> [CodexLineageLedger.DailyRow] {
        values.map { key, value in
            .init(day: key.day, model: key.model, totals: value.totals, costUSD: value.isPriced ? value.costUSD : nil)
        }.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }

    private static func inputFingerprint(
        documents: [CodexLineageLedger.Document],
        unresolvedParents: Set<CodexLineageLedger.ParentIdentity>,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> Fingerprint
    {
        var digest = DigestBuilder()
        digest.append("codex-lineage-family")
        digest.append(String(Self.algorithmVersion))
        for document in documents {
            try checkCancellation?()
            digest.append(contentsOf: [
                "document", document.scopeID, Self.canonical(document.ownerID),
                document.metadataSessionID.map(Self.canonical) ?? "",
                document.parentSessionID.map(Self.canonical) ?? "",
                String(document.incompleteObservationCount),
            ])
            let observations = document.observations.sorted(by: Self.observationComesBefore)
            for observation in observations {
                try checkCancellation?()
                digest.append(contentsOf: [
                    "observation", observation.timestamp, observation.model,
                    String(observation.last.input), String(observation.last.cached), String(observation.last.output),
                    String(observation.total.input), String(observation.total.cached), String(observation.total.output),
                ])
            }
        }
        for parent in unresolvedParents.sorted(by: { ($0.scopeID, $0.sessionID) < ($1.scopeID, $1.sessionID) }) {
            digest.append(contentsOf: ["unresolved", parent.scopeID, Self.canonical(parent.sessionID)])
        }
        return digest.finalize()
    }

    private static func descriptorFamilyFingerprint(
        descriptors: [CodexLineageTwoPassDiscovery.Descriptor],
        unresolvedParents: Set<CodexLineageLedger.ParentIdentity>) -> Fingerprint
    {
        var digest = DigestBuilder()
        digest.append(contentsOf: ["codex-lineage-descriptor-family", String(Self.algorithmVersion)])
        for descriptor in descriptors {
            digest.append(contentsOf: [
                "descriptor", descriptor.scopeID, Self.canonical(descriptor.ownerID),
                descriptor.metadataSessionID.map(Self.canonical) ?? "",
                descriptor.parentSessionID.map(Self.canonical) ?? "",
                String(descriptor.incompleteObservationCount), String(descriptor.observationCount),
                String(descriptor.signature.size), String(descriptor.signature.modifiedMilliseconds),
                descriptor.signature.contentSHA256,
            ])
        }
        for parent in unresolvedParents.sorted(by: { ($0.scopeID, $0.sessionID) < ($1.scopeID, $1.sessionID) }) {
            digest.append(contentsOf: ["unresolved", parent.scopeID, Self.canonical(parent.sessionID)])
        }
        return digest.finalize()
    }

    private static func descriptorKey(_ descriptor: CodexLineageTwoPassDiscovery.Descriptor) -> String {
        [
            descriptor.scopeID, self.canonical(descriptor.ownerID),
            descriptor.metadataSessionID.map(self.canonical) ?? "",
            descriptor.parentSessionID.map(self.canonical) ?? "",
            descriptor.signature.contentSHA256,
            descriptor.fileURL.standardizedFileURL.path,
        ].joined(separator: "\u{0}")
    }

    private static func familyFingerprint(
        input: Fingerprint,
        quality: CodexLineageLedger.FamilyQuality) -> Fingerprint
    {
        let qualityFields = switch quality {
        case .primary:
            ["primary"]
        case .incompleteProvenance:
            ["incompleteProvenance"]
        case let .contained(reasons):
            ["contained"] + reasons.map(\.rawValue).sorted()
        }
        return Self.digest(["codex-lineage-family-result", input.value] + qualityFields)
    }

    private static func cacheFingerprint(input: Fingerprint, localTimeZone: TimeZone) -> Fingerprint {
        self.digest([
            "codex-lineage-family-projection",
            input.value,
            localTimeZone.identifier,
        ])
    }

    private static func digest(_ fields: [String]) -> Fingerprint {
        var digest = DigestBuilder()
        for field in fields {
            digest.append(field)
        }
        return digest.finalize()
    }

    private static func documentFingerprint(
        _ document: CodexLineageLedger.Document,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> Fingerprint
    {
        let observations = document.observations.sorted(by: Self.observationComesBefore)
        var digest = DigestBuilder()
        digest.append(contentsOf: [
            document.scopeID, Self.canonical(document.ownerID),
            document.metadataSessionID.map(Self.canonical) ?? "",
            document.parentSessionID.map(Self.canonical) ?? "",
            String(document.incompleteObservationCount),
        ])
        for observation in observations {
            try checkCancellation?()
            digest.append(contentsOf: [
                observation.timestamp, observation.model,
                String(observation.last.input), String(observation.last.cached), String(observation.last.output),
                String(observation.total.input), String(observation.total.cached), String(observation.total.output),
            ])
        }
        return digest.finalize()
    }

    private static func observationComesBefore(
        _ lhs: CodexLineageLedger.Observation,
        _ rhs: CodexLineageLedger.Observation) -> Bool
    {
        self.observationKey(lhs) < self.observationKey(rhs)
    }

    private static func observationKey(_ observation: CodexLineageLedger.Observation) -> String {
        [
            observation.timestamp, observation.model,
            String(observation.last.input), String(observation.last.cached), String(observation.last.output),
            String(observation.total.input), String(observation.total.cached), String(observation.total.output),
        ].joined(separator: "\u{0}")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func canonical(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }

    private static func scoped(_ value: String, scopeID: String) -> String {
        scopeID + "\u{0}" + self.canonical(value)
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1000 + Int64(components.attoseconds / 1_000_000_000_000_000)
    }

    private struct DisjointSet {
        var parents: [String: String] = [:]

        mutating func insert(_ value: String) {
            self.parents[value] = self.parents[value] ?? value
        }

        mutating func find(_ value: String) -> String {
            self.insert(value)
            guard let parent = self.parents[value], parent != value else { return value }
            let root = self.find(parent)
            self.parents[value] = root
            return root
        }

        mutating func union(_ lhs: String, _ rhs: String) {
            let lhsRoot = self.find(lhs)
            let rhsRoot = self.find(rhs)
            guard lhsRoot != rhsRoot else { return }
            let first = min(lhsRoot, rhsRoot)
            let second = max(lhsRoot, rhsRoot)
            self.parents[second] = first
        }
    }

    private struct DigestBuilder {
        private var hasher = SHA256()

        mutating func append(_ field: String) {
            var length = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { self.hasher.update(bufferPointer: $0) }
            self.hasher.update(data: Data(field.utf8))
        }

        mutating func append(contentsOf fields: [String]) {
            for field in fields {
                self.append(field)
            }
        }

        consuming func finalize() -> Fingerprint {
            Fingerprint(value: self.hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
}
