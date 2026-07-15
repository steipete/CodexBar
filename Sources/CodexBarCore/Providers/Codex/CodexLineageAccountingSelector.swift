import Foundation

enum CodexLineageAccountingMode: String, CaseIterable, Sendable {
    case legacy
    case shadow
    case lineage

    static let defaultMode: Self = .legacy
    static let schemaVersion = 1

    var producerKeySuffix: String {
        "lineage-accounting:\(self.rawValue):v\(Self.schemaVersion)"
    }
}

/// Selects one whole-scan authority while preserving a permanent family-scoped containment route.
enum CodexLineageAccountingSelector {
    typealias PackedDays = [String: [String: [Int]]]

    enum SelectionError: Error, Equatable {
        case missingContainedFamilyEvidence
    }

    struct ContainedDocument: Equatable, Sendable {
        /// Stable logical rollout identity. Physical active/archive copies share this value.
        let identity: String
        let days: PackedDays
    }

    struct ContainedFamily: Equatable, Sendable {
        /// Legacy file contributions belonging only to this contained family.
        let documents: [ContainedDocument]
    }

    struct Selection: Equatable, Sendable {
        let days: PackedDays
        let usedLineageAuthority: Bool
        let containedFamilyCount: Int
    }

    static func select(
        mode: CodexLineageAccountingMode,
        authorization: CodexLineagePromotionEvaluator.Authorization? = nil,
        legacyDays: PackedDays,
        primaryRows: [CodexLineageLedger.DailyRow],
        containedFamilies: [ContainedFamily]) -> Selection
    {
        guard mode == .lineage, authorization != nil else {
            return Selection(days: legacyDays, usedLineageAuthority: false, containedFamilyCount: 0)
        }
        var days = Self.days(from: primaryRows)
        for family in containedFamilies {
            Self.add(Self.containedDays(family.documents), to: &days)
        }
        return Selection(
            days: days,
            usedLineageAuthority: true,
            containedFamilyCount: containedFamilies.count)
    }

    /// A contained family contributes once. Physical copies of one logical rollout use an envelope;
    /// distinct siblings remain additive so containment does not discard their independent work.
    private static func containedDays(_ documents: [ContainedDocument]) -> PackedDays {
        var documentsByIdentity: [String: [PackedDays]] = [:]
        for document in documents {
            documentsByIdentity[document.identity, default: []].append(document.days)
        }
        var result: PackedDays = [:]
        for copies in documentsByIdentity.values {
            var envelope: PackedDays = [:]
            for copy in copies {
                for (day, models) in copy {
                    for (model, packed) in models {
                        let existing = envelope[day]?[model] ?? [0, 0, 0]
                        envelope[day, default: [:]][model] = (0..<3).map { index in
                            max(existing[safe: index] ?? 0, packed[safe: index] ?? 0)
                        }
                    }
                }
            }
            Self.add(envelope, to: &result)
        }
        return result
    }

    private static func days(from rows: [CodexLineageLedger.DailyRow]) -> PackedDays {
        var days: PackedDays = [:]
        for row in rows {
            var packed = days[row.day]?[row.model] ?? [0, 0, 0]
            packed[0] += row.totals.input
            packed[1] += row.totals.cached
            packed[2] += row.totals.output
            days[row.day, default: [:]][row.model] = packed
        }
        return days
    }

    private static func add(_ source: PackedDays, to destination: inout PackedDays) {
        for (day, models) in source {
            for (model, packed) in models {
                var value = destination[day]?[model] ?? [0, 0, 0]
                for index in 0..<3 {
                    value[index] += packed[safe: index] ?? 0
                }
                destination[day, default: [:]][model] = value
            }
        }
    }
}
