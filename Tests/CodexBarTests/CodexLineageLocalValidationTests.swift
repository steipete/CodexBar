import Foundation
import Testing
@testable import CodexBarCore
#if os(macOS)
import Darwin
#endif

/// Opt-in aggregate-only replay. Run with `TZ=UTC CODEXBAR_RUN_LINEAGE_VALIDATION=1 swift test --filter ...`.
/// Never print rollout paths, identities, models, or contents.
struct CodexLineageLocalValidationTests {
    private enum ValidationError: Error {
        case extraFileOutsideCodexHome
        case extraFileOutsideRolloutRoots
        case extraFileMissingFromSnapshot
        case invalidReferenceTotals
    }

    private struct Reference: Codable {
        let tokens: Int
        let finalized: Bool
    }

    @Test
    func `local branch frontier diagnostic`() throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_VALIDATE_BRANCH_FRONTIERS_ONLY"] == "1" else { return }
        CodexBarLog.setLogLevel(.critical)
        let root = try #require(ProcessInfo.processInfo.environment["CODEXBAR_LINEAGE_VALIDATION_ROOT"])
        let snapshotHome = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
        let roots = [
            snapshotHome.appendingPathComponent("sessions", isDirectory: true),
            snapshotHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        let included = Self.rollouts(roots: roots, days: Self.discoveryDays)
        let report = try Self.branchFrontierDiagnostics(includedFiles: included, roots: roots)
        let output: [String: Any] = [
            "families": report.familyCount,
            "eligibleFamilies": report.eligibleFamilyCount,
            "ambiguousOwnerHistories": report.ambiguousOwnerHistoryCount,
            "resolvedParentEdges": report.resolvedParentEdgeCount,
            "unresolvedParentEdges": report.unresolvedParentEdgeCount,
            "sharedPrefixFingerprints": report.sharedPrefixFingerprintCount,
            "strongPostFrontierFingerprints": report.strongPostFrontierFingerprintCount,
            "ambiguousPostFrontierFingerprints": report.ambiguousPostFrontierFingerprintCount,
            "ambiguousBranchInstances": report.ambiguousPostFrontierBranchInstanceCount,
            "unknownPostFrontierFingerprints": report.unknownPostFrontierFingerprintCount,
            "estimatedSuppressedTokens": report.estimatedSuppressed.input + report.estimatedSuppressed.output,
            "estimatedSuppressedUTC": report.estimatedSuppressedUTC.mapValues { $0.input + $0.output },
            "peakFamilyObservations": report.peakFamilyObservationCount,
            "skippedOversizeFamilies": report.skippedOversizeFamilyCount,
            "overflowedEstimates": report.overflowedEstimateCount,
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        let encoded = try #require(String(bytes: data, encoding: .utf8))
        print("CODEX_LINEAGE_BRANCH_FRONTIERS " + encoded)
    }

    @Test
    func `local reset epoch diagnostic`() throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_VALIDATE_RESET_EPOCHS_ONLY"] == "1" else { return }
        CodexBarLog.setLogLevel(.critical)
        let root = try #require(ProcessInfo.processInfo.environment["CODEXBAR_LINEAGE_VALIDATION_ROOT"])
        let snapshotHome = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
        let roots = [
            snapshotHome.appendingPathComponent("sessions", isDirectory: true),
            snapshotHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        let included = Self.rollouts(roots: roots, days: Self.discoveryDays)
        let report = try Self.resetEpochDiagnostics(includedFiles: included, roots: roots)
        let output: [String: Any] = [
            "strongResetBoundaries": report.strongResetBoundaryCount,
            "mixedRegressions": report.mixedRegressionCount,
            "postResetRepeatedFingerprints": report.postResetRepeatedFingerprintCount,
            "sameOwnerRepeats": report.sameOwnerRepeatCount,
            "crossOwnerRepeats": report.crossOwnerRepeatCount,
            "estimatedSuppressedTokens": report.estimatedSuppressed.input + report.estimatedSuppressed.output,
            "estimatedSuppressedUTC": report.estimatedSuppressedUTC.mapValues { $0.input + $0.output },
            "sameOwnerEstimatedSuppressedTokens": report.sameOwnerEstimatedSuppressed.input
                + report.sameOwnerEstimatedSuppressed.output,
            "sameOwnerEstimatedSuppressedUTC": report.sameOwnerEstimatedSuppressedUTC.mapValues {
                $0.input + $0.output
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        let encoded = try #require(String(bytes: data, encoding: .utf8))
        print("CODEX_LINEAGE_RESET_EPOCHS " + encoded)
    }

    // The opt-in replay is intentionally linear so its immutable snapshot, scan, and comparison
    // lifecycle stays auditable in one place.
    // swiftlint:disable function_body_length
    @Test
    func `local UTC lineage validation`() throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_RUN_LINEAGE_VALIDATION"] == "1" else { return }
        CodexBarLog.setLogLevel(.critical)
        let home = URL(fileURLWithPath: ("~/.codex" as NSString).expandingTildeInPath, isDirectory: true)
        let existingRoot = ProcessInfo.processInfo.environment["CODEXBAR_LINEAGE_VALIDATION_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let validationRoot = existingRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-lineage-validation-\(UUID().uuidString)", isDirectory: true)
        defer {
            if existingRoot == nil {
                try? FileManager.default.removeItem(at: validationRoot)
            }
        }
        let snapshotHome = validationRoot.appendingPathComponent("codex-home", isDirectory: true)
        if !FileManager.default.fileExists(atPath: snapshotHome.path) {
            try Self.snapshotCodexHome(source: home, destination: snapshotHome)
        }
        let sessions = snapshotHome.appendingPathComponent("sessions", isDirectory: true)
        let archived = snapshotHome.appendingPathComponent("archived_sessions", isDirectory: true)
        let included = try Array(Set(
            Self.rollouts(roots: [sessions, archived], days: Self.discoveryDays)
                + (Self.extraValidationFiles(sourceHome: home, snapshotHome: snapshotHome))))
            .sorted { $0.path < $1.path }
        let cacheRoot = validationRoot.appendingPathComponent("legacy", isDirectory: true)
        Self.progress("snapshot-ready")

        var options = CostUsageScanner.Options(
            codexSessionsRoot: sessions,
            cacheRoot: cacheRoot,
            codexLineageAccountingMode: .legacy,
            forceRescan: true)
        // A retained snapshot may be replayed, but scanner caches must never influence the result.
        options.refreshMinIntervalSeconds = 0
        let since = try #require(ISO8601DateFormatter().date(from: "2026-07-05T00:00:00Z"))
        let until = try #require(ISO8601DateFormatter().date(from: "2026-07-12T23:59:59Z"))
        let legacyStarted = ContinuousClock.now
        let legacyReport = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: since,
            until: until,
            now: until,
            options: options,
            checkCancellation: nil)
        let legacyDuration = legacyStarted.duration(to: .now)
        let legacy = Dictionary(uniqueKeysWithValues: legacyReport.data.map {
            ($0.date, ($0.inputTokens ?? 0) + ($0.outputTokens ?? 0))
        })
        let legacyCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot)
        let references = try Self.referenceTotals()
        Self.progress("legacy-ready")

        let resetEpochDiagnostics: CodexLineageResetEpochDiagnostics.Report? = if ProcessInfo.processInfo
            .environment["CODEXBAR_VALIDATE_RESET_EPOCHS"] == "1"
        {
            try Self.resetEpochDiagnostics(includedFiles: included, roots: [sessions, archived])
        } else {
            nil
        }

        let directModes: [CodexLineageAccountingMode] = switch ProcessInfo.processInfo
            .environment["CODEXBAR_VALIDATE_SCANNER_MODES"]
        {
        case "shadow": [.shadow]
        case "lineage": [.lineage]
        case "all": [.shadow, .lineage]
        default: []
        }
        var directReports: [String: [String: Int]] = [:]
        for mode in directModes {
            let modeRoot = validationRoot.appendingPathComponent(mode.rawValue, isDirectory: true)
            var modeOptions = CostUsageScanner.Options(
                codexSessionsRoot: sessions,
                cacheRoot: modeRoot,
                codexLineageAccountingMode: mode,
                forceRescan: true)
            modeOptions.refreshMinIntervalSeconds = 0
            let report = try CostUsageScanner.loadDailyReportCancellable(
                provider: .codex,
                since: since,
                until: until,
                now: until,
                options: modeOptions,
                checkCancellation: nil)
            directReports[mode.rawValue] = Dictionary(uniqueKeysWithValues: report.data.map {
                ($0.date, ($0.inputTokens ?? 0) + ($0.outputTokens ?? 0))
            })
        }

        let lineageStarted = ContinuousClock.now
        Self.progress("discovery-start")
        let discovery = try CodexLineageTwoPassDiscovery.discover(
            includedFiles: included,
            roots: [sessions, archived])
        Self.progress("discovery-ready")
        let families = try CodexLineageEngine.prepareDescriptorFamilies(
            descriptors: discovery.descriptors,
            unresolvedParents: discovery.unresolvedParents)
        Self.progress("families-ready")
        let lineage = try CodexLineageEngine.reconcileStreaming(families: families, localTimeZone: .gmt)
        Self.progress("lineage-ready")
        let lineageDuration = lineageStarted.duration(to: .now)
        let resultsByID = Dictionary(uniqueKeysWithValues: lineage.families.map { ($0.stableID, $0) })
        var containmentReasons: [String: Int] = [:]
        var containedObservationCount = 0
        for family in families {
            guard let result = resultsByID[family.stableID], case let .contained(reasons) = result.quality else {
                continue
            }
            containedObservationCount += family.observationCount
            for reason in reasons {
                containmentReasons[reason.rawValue, default: 0] += 1
            }
        }
        let containedFamilyCount = families.count { family in
            guard let result = resultsByID[family.stableID] else { return false }
            if case .contained = result.quality {
                return true
            }
            return false
        }
        let selectableContainedFamilies = families
            .compactMap { family -> CodexLineageAccountingSelector.ContainedFamily? in
                guard let result = resultsByID[family.stableID], case .contained = result.quality else { return nil }
                let documents = family.descriptors.compactMap { descriptor ->
                    CodexLineageAccountingSelector.ContainedDocument? in
                    guard let days = legacyCache.files[descriptor.fileURL.path]?.days else { return nil }
                    let identity = CostUsageScanner.codexContainedDocumentIdentity(
                        scopeID: descriptor.scopeID,
                        ownerID: descriptor.ownerID)
                    return .init(identity: identity, days: days)
                }
                return documents.count == family.descriptors.count ? .init(documents: documents) : nil
            }
        guard selectableContainedFamilies.count == containedFamilyCount else {
            // Match the production selector's fail-closed behavior. A partial contained fallback
            // would make the replay look better by silently dropping a family.
            throw CodexLineageAccountingSelector.SelectionError.missingContainedFamilyEvidence
        }
        let selected = CodexLineageAccountingSelector.select(
            mode: .lineage,
            legacyDays: legacyCache.days,
            primaryRows: lineage.report.utcRows,
            containedFamilies: selectableContainedFamilies)
        let primary = Self.tokensByDay(lineage.report.utcRows)
        let selectedTokens = Self.tokensByDay(selected.days)
        let contained = Dictionary(uniqueKeysWithValues: Self.referenceDays.map { day in
            (day, max(0, (selectedTokens[day] ?? 0) - (primary[day] ?? 0)))
        })

        let samples = Self.referenceDays.map { day -> CodexLineageResidualClassifier.Sample in
            let reference = references[day] ?? Reference(tokens: legacy[day] ?? 0, finalized: false)
            return .init(
                day: day,
                referenceTokens: reference.tokens,
                isReferenceFinalized: reference.finalized,
                isOrdinaryDay: false,
                legacyTokens: legacy[day] ?? 0,
                ledgerUTCTokens: selectedTokens[day] ?? 0,
                ledgerLocalTokens: selectedTokens[day] ?? 0,
                evidence: .init(
                    // Date-filtered replay can prove referenced-parent closure, not full corpus
                    // exhaustiveness: unreferenced or deleted historical documents may be absent.
                    localCorpusWasExhaustive: false,
                    rejectedObservationCount: discovery.descriptors.reduce(0) {
                        $0 + $1.incompleteObservationCount
                    },
                    unresolvedParentCount: discovery.unresolvedParents.count,
                    duplicateObservationCount: lineage.report.duplicateObservationCount))
        }
        let classification = CodexLineageResidualClassifier.classify(samples: samples)
        let ordinaryDivergenceCount = Self.ordinaryDays.count { day in
            let legacyTokens = legacy[day] ?? 0
            guard legacyTokens > 0 else { return false }
            return abs((selectedTokens[day] ?? 0) - legacyTokens) > Int(Double(legacyTokens) * 0.01)
        }

        let output: [String: Any] = [
            "days": Self.referenceDays.map { day in
                let result = classification.days.first { $0.day == day }
                return [
                    "day": day,
                    "legacy": legacy[day] ?? 0,
                    "primary": primary[day] ?? 0,
                    "contained": contained[day] ?? 0,
                    "selected": selectedTokens[day] ?? 0,
                    "shadow": directReports[CodexLineageAccountingMode.shadow.rawValue]?[day] ?? 0,
                    "scannerLineage": directReports[CodexLineageAccountingMode.lineage.rawValue]?[day] ?? 0,
                    "reference": references[day]?.tokens ?? 0,
                    "finalized": references[day]?.finalized ?? false,
                    "classification": result?.classification.rawValue ?? "missing",
                ] as [String: Any]
            },
            "ordinaryDays": Self.ordinaryDays.map { day in
                [
                    "day": day,
                    "legacy": legacy[day] ?? 0,
                    "selected": selectedTokens[day] ?? 0,
                ] as [String: Any]
            },
            "coverage": [
                "documents": discovery.descriptors.count,
                "families": lineage.diagnostics.familyCount,
                "containedFamilies": containedFamilyCount,
                "selectableContainedFamilies": selectableContainedFamilies.count,
                "containedObservations": containedObservationCount,
                "containmentReasons": containmentReasons,
                "referencedParents": discovery.referencedParentDocumentCount,
                "unresolvedParents": discovery.unresolvedParents.count,
                "observations": lineage.diagnostics.observationCount,
                "peakFamilyObservations": lineage.diagnostics.peakFamilyObservationCount,
                "duplicateObservations": lineage.report.duplicateObservationCount,
            ],
            "performance": [
                "legacyMilliseconds": Self.milliseconds(legacyDuration),
                "lineageMilliseconds": Self.milliseconds(lineageDuration),
            ],
            "ordinaryDayDivergenceCount": ordinaryDivergenceCount,
            "resetEpochDiagnostics": [
                "strongResetBoundaries": resetEpochDiagnostics?.strongResetBoundaryCount ?? 0,
                "mixedRegressions": resetEpochDiagnostics?.mixedRegressionCount ?? 0,
                "postResetRepeatedFingerprints": resetEpochDiagnostics?.postResetRepeatedFingerprintCount ?? 0,
                "sameOwnerRepeats": resetEpochDiagnostics?.sameOwnerRepeatCount ?? 0,
                "crossOwnerRepeats": resetEpochDiagnostics?.crossOwnerRepeatCount ?? 0,
                "estimatedSuppressedTokens": resetEpochDiagnostics.map {
                    $0.estimatedSuppressed.input + $0.estimatedSuppressed.output
                } ?? 0,
                "estimatedSuppressedUTC": resetEpochDiagnostics?.estimatedSuppressedUTC.mapValues {
                    $0.input + $0.output
                } ?? [:],
                "sameOwnerEstimatedSuppressedTokens": resetEpochDiagnostics.map {
                    $0.sameOwnerEstimatedSuppressed.input + $0.sameOwnerEstimatedSuppressed.output
                } ?? 0,
                "sameOwnerEstimatedSuppressedUTC": resetEpochDiagnostics?.sameOwnerEstimatedSuppressedUTC.mapValues {
                    $0.input + $0.output
                } ?? [:],
            ],
            "aggregateImproved": classification.improvesAggregateError,
            // This replay is one validation artifact, not permission to remove the rollback path.
            "supportsLegacyRemoval": false,
            "legacyRemovalBlocker": "requires-reviewed-multi-run-promotion-evidence",
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        let encoded = try #require(String(bytes: data, encoding: .utf8))
        print("CODEX_LINEAGE_VALIDATION " + encoded)
    }

    // swiftlint:enable function_body_length

    private static let referenceDays = ["2026-07-09", "2026-07-10", "2026-07-11", "2026-07-12"]
    private static let ordinaryDays = ["2026-07-05", "2026-07-06", "2026-07-07", "2026-07-08"]
    private static let discoveryDays = Set(Self.referenceDays + Self.ordinaryDays + ["2026-07-04", "2026-07-13"])

    /// Loads private account totals from an explicitly supplied, untracked JSON file.
    /// Format: `{ "YYYY-MM-DD": { "tokens": 123, "finalized": true } }`.
    private static func referenceTotals() throws -> [String: Reference] {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_LINEAGE_REFERENCE_TOTALS_FILE"] else {
            return [:]
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let references = try? JSONDecoder().decode([String: Reference].self, from: data),
              references.values.allSatisfy({ $0.tokens >= 0 })
        else {
            throw ValidationError.invalidReferenceTotals
        }
        return references
    }

    private static func resetEpochDiagnostics(
        includedFiles: [URL],
        roots: [URL]) throws -> CodexLineageResetEpochDiagnostics.Report
    {
        self.progress("reset-epoch-start")
        let discovery = try CodexLineageDiscovery.discover(includedFiles: includedFiles, roots: roots)
        let documents = discovery.documents.map { document in
            CodexLineageLedger.Document(
                ownerID: document.ownerID,
                metadataSessionID: document.metadataSessionID,
                parentSessionID: document.parentSessionID,
                observations: document.observations,
                scopeID: document.scopeID,
                incompleteObservationCount: document.incompleteObservationCount)
        }
        let families = try CodexLineageEngine.prepareFamilies(
            documents: documents,
            unresolvedParents: discovery.unresolvedParents)
        let report = try CodexLineageResetEpochDiagnostics.analyze(families: families)
        Self.progress("reset-epoch-ready")
        return report
    }

    private static func branchFrontierDiagnostics(
        includedFiles: [URL],
        roots: [URL]) throws -> CodexLineageBranchFrontierDiagnostics.Report
    {
        self.progress("branch-frontier-start")
        let discovery = try CodexLineageDiscovery.discover(includedFiles: includedFiles, roots: roots)
        let documents = discovery.documents.map { document in
            CodexLineageLedger.Document(
                ownerID: document.ownerID,
                metadataSessionID: document.metadataSessionID,
                parentSessionID: document.parentSessionID,
                observations: document.observations,
                scopeID: document.scopeID,
                incompleteObservationCount: document.incompleteObservationCount)
        }
        let families = try CodexLineageEngine.prepareFamilies(
            documents: documents,
            unresolvedParents: discovery.unresolvedParents)
        let report = try CodexLineageBranchFrontierDiagnostics.analyze(families: families)
        Self.progress("branch-frontier-ready")
        return report
    }

    private static func rollouts(roots: [URL], days: Set<String>) -> [URL] {
        roots.flatMap { root -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return [] }
            return enumerator.compactMap { value -> URL? in
                guard let url = value as? URL, url.pathExtension.lowercased() == "jsonl" else { return nil }
                return days.contains(where: url.path.contains) ? url : nil
            }
        }.sorted { $0.path < $1.path }
    }

    private static func extraValidationFiles(sourceHome: URL, snapshotHome: URL) throws -> [URL] {
        guard let listPath = ProcessInfo.processInfo.environment["CODEXBAR_LINEAGE_EXTRA_FILE_LIST"],
              let contents = try? String(contentsOfFile: listPath, encoding: .utf8)
        else { return [] }
        let canonicalSourceHome = sourceHome.standardizedFileURL.resolvingSymlinksInPath().path
        return try contents.split(whereSeparator: \.isNewline).map { line in
            let source = URL(fileURLWithPath: String(line)).standardizedFileURL.resolvingSymlinksInPath()
            guard source.path.hasPrefix(canonicalSourceHome + "/") else {
                throw ValidationError.extraFileOutsideCodexHome
            }
            let relative = source.path.dropFirst(canonicalSourceHome.count + 1)
            guard relative.hasPrefix("sessions/") || relative.hasPrefix("archived_sessions/") else {
                throw ValidationError.extraFileOutsideRolloutRoots
            }
            let snapshot = snapshotHome.appendingPathComponent(String(relative)).standardizedFileURL
            guard FileManager.default.fileExists(atPath: snapshot.path) else {
                throw ValidationError.extraFileMissingFromSnapshot
            }
            return snapshot
        }
    }

    private static func snapshotCodexHome(source: URL, destination: URL) throws {
        for rootName in ["sessions", "archived_sessions"] {
            let sourceRoot = source.appendingPathComponent(rootName, isDirectory: true)
            let destinationRoot = destination.appendingPathComponent(rootName, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            while let sourceFile = enumerator.nextObject() as? URL {
                guard sourceFile.pathExtension.lowercased() == "jsonl" else { continue }
                let relativePath = sourceFile.path.dropFirst(sourceRoot.path.count + 1)
                let destinationFile = destinationRoot.appendingPathComponent(String(relativePath))
                try FileManager.default.createDirectory(
                    at: destinationFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try Self.cloneOrCopy(source: sourceFile, destination: destinationFile)
            }
        }
    }

    private static func cloneOrCopy(source: URL, destination: URL) throws {
        #if os(macOS)
        if clonefile(source.path, destination.path, 0) == 0 {
            return
        }
        #endif
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func tokensByDay(_ rows: [CodexLineageLedger.DailyRow]) -> [String: Int] {
        rows.reduce(into: [:]) { $0[$1.day, default: 0] += $1.totals.input + $1.totals.output }
    }

    private static func tokensByDay(_ days: CodexLineageAccountingSelector.PackedDays) -> [String: Int] {
        days.mapValues { models in models.values.reduce(0) { $0 + ($1[safe: 0] ?? 0) + ($1[safe: 2] ?? 0) } }
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1000 + Int64(components.attoseconds / 1_000_000_000_000_000)
    }

    private static func progress(_ stage: String) {
        print("CODEX_LINEAGE_STAGE " + stage)
        fflush(stdout)
    }
}
