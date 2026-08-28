import Foundation

extension CostUsageScanner {
    enum CodexSubagentCounterSemantics: Equatable {
        case independent
        case copiedPrefix
    }

    /// Subagent source is lineage evidence, not counter semantics. The first session metadata
    /// owns leaf identity. Embedded ancestor metadata proves a copied prefix by itself. Compact
    /// rollouts need a first-turn boundary plus either local `total - last` proof or an exact parent
    /// snapshot match in the scanner. Do not restore a blanket "all subagents are
    /// independent/inherited" rule.
    struct CodexSubagentRolloutShape {
        let counterSemantics: CodexSubagentCounterSemantics
        let ownedSuffix: CodexSubagentOwnedSuffix?
        let ownedSuffixCandidate: CodexSubagentOwnedSuffixCandidate?
        let inferredParentSessionID: String?

        struct CodexSubagentOwnedSuffix {
            let startLineIndex: Int
            let rawTotalsBaseline: CostUsageCodexTotals
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

            let hasEmbeddedAncestor: Bool = if let normalizedLeafID {
                observedSessionIDs.contains { Self.normalizedSessionID($0) != normalizedLeafID }
            } else {
                observedSessionIDs.count > 1 || observedSessionIDs.contains { Self.normalizedSessionID($0) != nil }
            }
            let distinctAncestorIDs = Set(observedSessionIDs
                .compactMap(Self.normalizedSessionID)
                .filter { normalizedLeafID == nil || $0 != normalizedLeafID })
            let inferredParentSessionID = distinctAncestorIDs.count == 1 ? distinctAncestorIDs.first : nil

            return Self(
                counterSemantics: hasEmbeddedAncestor ? .copiedPrefix : .independent,
                ownedSuffix: nil,
                ownedSuffixCandidate: nil,
                inferredParentSessionID: inferredParentSessionID)
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
                    if !inspectedOwnedSuffixFirstTotal,
                       let suffix = ownedSuffix,
                       let total
                    {
                        inspectedOwnedSuffixFirstTotal = true
                        if let last,
                           Self.totalsEqual(total, last),
                           !Self.totalsAtLeast(total, suffix.rawTotalsBaseline)
                        {
                            // Some future protocol may copy history and then restart its counter.
                            // Require both a strong boundary and total==last reset evidence.
                            ownedSuffix = Self.CodexSubagentOwnedSuffix(
                                startLineIndex: suffix.startLineIndex,
                                rawTotalsBaseline: .init(input: 0, cached: 0, output: 0))
                        } else if let last,
                                  let inferredBaseline = Self.subtract(last, from: total),
                                  Self.totalsEqual(inferredBaseline, suffix.rawTotalsBaseline)
                        {
                            // Local delivery metadata is not part of copied model history. When
                            // the first owned cumulative row also proves total - last == the
                            // pre-boundary snapshot, the child can establish its inherited
                            // baseline without rereading the parent rollout.
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

        private static func totalsEqual(_ lhs: CostUsageCodexTotals, _ rhs: CostUsageCodexTotals) -> Bool {
            lhs.input == rhs.input && lhs.cached == rhs.cached && lhs.output == rhs.output
        }

        private static func totalsAtLeast(_ lhs: CostUsageCodexTotals, _ rhs: CostUsageCodexTotals) -> Bool {
            lhs.input >= rhs.input && lhs.cached >= rhs.cached && lhs.output >= rhs.output
        }

        private static func totalsContainUsage(_ totals: CostUsageCodexTotals) -> Bool {
            totals.input > 0 || totals.cached > 0 || totals.output > 0
        }

        private static func subtract(
            _ delta: CostUsageCodexTotals,
            from total: CostUsageCodexTotals) -> CostUsageCodexTotals?
        {
            guard self.totalsAtLeast(total, delta) else { return nil }
            let reasoning: Int? = if let totalReasoning = total.reasoning,
                                     let deltaReasoning = delta.reasoning,
                                     totalReasoning >= deltaReasoning
            {
                totalReasoning - deltaReasoning
            } else {
                nil
            }
            return CostUsageCodexTotals(
                input: total.input - delta.input,
                cached: total.cached - delta.cached,
                output: total.output - delta.output,
                reasoning: reasoning)
        }

        private static func normalizedSessionID(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
