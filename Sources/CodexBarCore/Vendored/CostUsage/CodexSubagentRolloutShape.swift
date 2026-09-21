import Foundation

extension CostUsageScanner {
    enum CodexSubagentCounterSemantics: Equatable {
        case independent
        case copiedPrefix
    }

    /// Subagent source is lineage evidence, not counter semantics. The first session metadata
    /// owns leaf identity. Embedded ancestor metadata proves a copied prefix by itself. Compact
    /// rollouts can establish inheritance from a zero-usage opening snapshot or a first-turn
    /// boundary. The first owned event supplies its component baseline; inherited snapshots
    /// need not exactly match it. Independently restarted counters still count their opening usage.
    struct CodexSubagentRolloutShape {
        let counterSemantics: CodexSubagentCounterSemantics
        let ownedSuffix: CodexSubagentOwnedSuffix?
        let ownedSuffixCandidate: CodexSubagentOwnedSuffixCandidate?
        let inferredParentSessionID: String?

        struct CodexSubagentOwnedSuffix {
            let startLineIndex: Int
            let rawTotalsBaseline: CostUsageCodexTotals
            var firstTokenLineIndex: Int?
        }

        struct CodexSubagentOwnedSuffixCandidate {
            let ownedSuffix: CodexSubagentOwnedSuffix
            let parentTotalsAtBoundary: CostUsageCodexTotals
            let isLocallyConfirmed: Bool
        }

        struct Observation {
            let lineIndex: Int
            let kind: Kind

            enum Kind {
                case sessionMetadata(id: String?)
                case turnContext
                case interAgentCommunication(triggerTurn: Bool)
                case tokenCount(total: CostUsageCodexTotals?, last: CostUsageCodexTotals?)
            }
        }

        static func classify(
            leafSessionID: String?,
            observedSessionIDs: [String?]) -> Self
        {
            let normalizedLeafID = Self.normalizedSessionID(leafSessionID)

            let ancestorIDs = observedSessionIDs.map(Self.normalizedSessionID).filter { $0 != normalizedLeafID }
            let hasEmbeddedAncestor = !ancestorIDs.isEmpty || (normalizedLeafID == nil && observedSessionIDs.count > 1)
            let distinctAncestorIDs = Set(ancestorIDs.compactMap(\.self))

            return Self(
                counterSemantics: hasEmbeddedAncestor ? .copiedPrefix : .independent,
                ownedSuffix: nil,
                ownedSuffixCandidate: nil,
                inferredParentSessionID: distinctAncestorIDs.count == 1 ? distinctAncestorIDs.first : nil)
        }

        static func classify(
            leafSessionID: String?,
            observations: [Observation],
            hasExplicitParent: Bool = false) -> Self
        {
            let metadataIDs = observations.reduce(into: [String?]()) { result, observation in
                guard case let .sessionMetadata(id) = observation.kind else { return }
                result.append(id)
            }
            let metadataShape = Self.classify(
                leafSessionID: leafSessionID,
                observedSessionIDs: metadataIDs)
            let canProposeParentConfirmedSuffix = metadataShape.counterSemantics == .independent
                && hasExplicitParent
            guard metadataShape.counterSemantics == .copiedPrefix || canProposeParentConfirmedSuffix
            else { return metadataShape }

            let normalizedLeafID = Self.normalizedSessionID(leafSessionID)
            var lastRawTotals: CostUsageCodexTotals?
            var pendingTurnContext: (lineIndex: Int, baseline: CostUsageCodexTotals)?
            var ownedSuffix: CodexSubagentOwnedSuffix?
            var parentTotalsAtBoundary: CostUsageCodexTotals?
            var locallyConfirmedBoundary = false
            var inspectedOwnedSuffixFirstTotal = false
            var observedAuthoritativeMetadata = false
            var observedTurnContext = false
            var inheritedOpening = false

            for observation in observations {
                switch observation.kind {
                case let .sessionMetadata(id):
                    let normalizedID = Self.normalizedSessionID(id)
                    let isEmbeddedAncestor: Bool = if !observedAuthoritativeMetadata {
                        false
                    } else if let normalizedLeafID {
                        normalizedID != normalizedLeafID
                    } else {
                        true
                    }
                    observedAuthoritativeMetadata = true
                    if isEmbeddedAncestor {
                        // A later ancestor meta proves that any earlier candidate boundary was replay.
                        ownedSuffix = nil
                        parentTotalsAtBoundary = nil
                        locallyConfirmedBoundary = false
                        inspectedOwnedSuffixFirstTotal = false
                    }
                    pendingTurnContext = nil

                case .turnContext:
                    let isFirstTurnContext = !observedTurnContext
                    observedTurnContext = true
                    let acceptsBoundary = metadataShape.counterSemantics == .copiedPrefix
                        || (canProposeParentConfirmedSuffix && isFirstTurnContext)
                    pendingTurnContext = acceptsBoundary
                        ? lastRawTotals.map { (observation.lineIndex, $0) }
                        : nil
                    if inheritedOpening, isFirstTurnContext, let pendingTurnContext {
                        ownedSuffix = .init(
                            startLineIndex: pendingTurnContext.lineIndex,
                            rawTotalsBaseline: pendingTurnContext.baseline)
                        inspectedOwnedSuffixFirstTotal = false
                    }

                case let .interAgentCommunication(triggerTurn):
                    if ownedSuffix == nil,
                       triggerTurn,
                       let pendingTurnContext,
                       observation.lineIndex == pendingTurnContext.lineIndex + 1,
                       metadataShape.counterSemantics == .copiedPrefix
                       || Self.totalsContainUsage(pendingTurnContext.baseline)
                    {
                        ownedSuffix = Self.CodexSubagentOwnedSuffix(
                            startLineIndex: pendingTurnContext.lineIndex,
                            rawTotalsBaseline: pendingTurnContext.baseline)
                        parentTotalsAtBoundary = pendingTurnContext.baseline
                        locallyConfirmedBoundary = false
                        inspectedOwnedSuffixFirstTotal = false
                    }
                    pendingTurnContext = nil

                case let .tokenCount(total, last):
                    if lastRawTotals == nil, canProposeParentConfirmedSuffix, !observedTurnContext,
                       let total, let last, Self.totalsContainUsage(total), !Self.totalsContainUsage(last)
                    {
                        // A zero-component opening event carries inherited context, not child usage.
                        inheritedOpening = true
                        ownedSuffix = .init(startLineIndex: observation.lineIndex, rawTotalsBaseline: total)
                        parentTotalsAtBoundary = total
                        locallyConfirmedBoundary = true
                    }
                    if inheritedOpening, !observedTurnContext,
                       let total, let last, Self.totalsContainUsage(last),
                       !CostUsageScanner.codexTotalsEqual(total, lastRawTotals)
                    {
                        inheritedOpening = false
                        ownedSuffix = .init(
                            startLineIndex: observation.lineIndex,
                            rawTotalsBaseline: lastRawTotals ?? total)
                        inspectedOwnedSuffixFirstTotal = false
                    }
                    if !inspectedOwnedSuffixFirstTotal,
                       let suffix = ownedSuffix,
                       let total,
                       !CostUsageScanner.codexTotalsEqual(total, suffix.rawTotalsBaseline)
                    {
                        inspectedOwnedSuffixFirstTotal = true
                        if let last {
                            let copiedSnapshot = Self.totalsContainUsage(suffix.rawTotalsBaseline)
                                && CostUsageScanner.codexTotalsEqual(total, last)
                                && CostUsageScanner.codexTotalsAtLeast(total, suffix.rawTotalsBaseline)
                            ownedSuffix = .init(
                                startLineIndex: suffix.startLineIndex,
                                rawTotalsBaseline: copiedSnapshot ? total : CostUsageScanner
                                    .codexTotalDelta(from: last, to: total),
                                firstTokenLineIndex: observation.lineIndex)
                            inspectedOwnedSuffixFirstTotal = !copiedSnapshot
                            locallyConfirmedBoundary = true
                        }
                    }
                    if let total {
                        lastRawTotals = total
                    }
                    pendingTurnContext = nil
                }
            }

            if metadataShape.counterSemantics == .copiedPrefix {
                return Self(
                    counterSemantics: .copiedPrefix,
                    ownedSuffix: ownedSuffix,
                    ownedSuffixCandidate: nil,
                    inferredParentSessionID: metadataShape.inferredParentSessionID)
            }

            let candidate: CodexSubagentOwnedSuffixCandidate? = if let ownedSuffix, let parentTotalsAtBoundary {
                Self.CodexSubagentOwnedSuffixCandidate(
                    ownedSuffix: ownedSuffix,
                    parentTotalsAtBoundary: parentTotalsAtBoundary,
                    isLocallyConfirmed: locallyConfirmedBoundary)
            } else {
                nil
            }
            return Self(
                counterSemantics: .independent,
                ownedSuffix: nil,
                ownedSuffixCandidate: candidate,
                inferredParentSessionID: metadataShape.inferredParentSessionID)
        }

        static func sameConcreteSessionID(_ lhs: String?, _ rhs: String?) -> Bool {
            guard let lhs = normalizedSessionID(lhs),
                  let rhs = normalizedSessionID(rhs)
            else { return false }
            return lhs == rhs
        }

        static func totalsContainUsage(_ totals: CostUsageCodexTotals) -> Bool {
            totals.input > 0 || totals.cached > 0 || totals.output > 0
        }

        private static func normalizedSessionID(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
