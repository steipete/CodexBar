import Testing
@testable import CodexBarCore

struct CodexSubagentRolloutShapeTests {
    @Test
    func `single leaf metadata means an independent counter`() {
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observedSessionIDs: ["leaf"])

        #expect(shape.counterSemantics == .independent)
    }

    @Test
    func `single leaf first turn marker proposes a parent-confirmed suffix`() throws {
        let baseline = CostUsageCodexTotals(input: 1000, cached: 900, output: 100)
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .tokenCount(total: baseline, last: baseline)),
                .init(lineIndex: 3, kind: .turnContext),
                .init(lineIndex: 4, kind: .interAgentCommunication(triggerTurn: true)),
            ],
            hasExplicitParent: true)

        let candidate = try #require(shape.ownedSuffixCandidate)
        #expect(shape.counterSemantics == .independent)
        #expect(shape.ownedSuffix == nil)
        #expect(candidate.ownedSuffix.startLineIndex == 3)
        #expect(candidate.parentTotalsAtBoundary.input == baseline.input)
        #expect(candidate.parentTotalsAtBoundary.cached == baseline.cached)
        #expect(candidate.parentTotalsAtBoundary.output == baseline.output)
    }

    @Test
    func `single leaf marker without an explicit parent stays independent`() {
        let baseline = CostUsageCodexTotals(input: 1000, cached: 900, output: 100)
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .tokenCount(total: baseline, last: baseline)),
                .init(lineIndex: 3, kind: .turnContext),
                .init(lineIndex: 4, kind: .interAgentCommunication(triggerTurn: true)),
            ])

        #expect(shape.counterSemantics == .independent)
        #expect(shape.ownedSuffixCandidate == nil)
    }

    @Test
    func `later marker after an earlier turn does not propose a suffix`() {
        let baseline = CostUsageCodexTotals(input: 1000, cached: 900, output: 100)
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .turnContext),
                .init(lineIndex: 2, kind: .tokenCount(total: baseline, last: baseline)),
                .init(lineIndex: 3, kind: .turnContext),
                .init(lineIndex: 4, kind: .interAgentCommunication(triggerTurn: true)),
            ],
            hasExplicitParent: true)

        #expect(shape.counterSemantics == .independent)
        #expect(shape.ownedSuffixCandidate == nil)
    }

    @Test
    func `zero pre-turn totals do not propose a suffix`() {
        let zero = CostUsageCodexTotals(input: 0, cached: 0, output: 0)
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .tokenCount(total: zero, last: zero)),
                .init(lineIndex: 2, kind: .turnContext),
                .init(lineIndex: 3, kind: .interAgentCommunication(triggerTurn: true)),
            ],
            hasExplicitParent: true)

        #expect(shape.ownedSuffixCandidate == nil)
    }

    @Test
    func `nonadjacent first-turn trigger does not propose a suffix`() {
        let baseline = CostUsageCodexTotals(input: 1000, cached: 900, output: 100)
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .tokenCount(total: baseline, last: baseline)),
                .init(lineIndex: 2, kind: .turnContext),
                .init(lineIndex: 4, kind: .interAgentCommunication(triggerTurn: true)),
            ],
            hasExplicitParent: true)

        #expect(shape.ownedSuffixCandidate == nil)
    }

    @Test
    func `embedded ancestor metadata means a copied prefix`() {
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observedSessionIDs: ["leaf", "parent"])

        #expect(shape.counterSemantics == .copiedPrefix)
        #expect(shape.inferredParentSessionID == "parent")
    }

    @Test
    func `multiple ancestors do not infer an ambiguous parent`() {
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observedSessionIDs: ["leaf", "parent", "grandparent"])

        #expect(shape.counterSemantics == .copiedPrefix)
        #expect(shape.inferredParentSessionID == nil)
    }

    @Test
    func `repeated leaf metadata does not invent an ancestor`() {
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observedSessionIDs: ["leaf", "leaf"])

        #expect(shape.counterSemantics == .independent)
    }

    @Test
    func `unknown leaf followed by a concrete metadata id is copied`() {
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: nil,
            observedSessionIDs: [nil, "parent"])

        #expect(shape.counterSemantics == .copiedPrefix)
        #expect(shape.inferredParentSessionID == "parent")
    }

    @Test
    func `idless metadata after a known leaf is conservatively copied`() {
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observedSessionIDs: ["leaf", nil])

        #expect(shape.counterSemantics == .copiedPrefix)
        #expect(shape.inferredParentSessionID == nil)
    }

    @Test
    func `only concrete normalized ids identify the same leaf`() {
        #expect(CostUsageScanner.CodexSubagentRolloutShape.sameConcreteSessionID(" leaf ", "leaf"))
        #expect(!CostUsageScanner.CodexSubagentRolloutShape.sameConcreteSessionID(nil, nil))
        #expect(!CostUsageScanner.CodexSubagentRolloutShape.sameConcreteSessionID("", ""))
    }

    @Test
    func `adjacent trigger after the final ancestor opens an owned suffix`() throws {
        let baseline = CostUsageCodexTotals(input: 1000, cached: 900, output: 100)
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 4, kind: .tokenCount(total: baseline, last: nil)),
                .init(lineIndex: 5, kind: .sessionMetadata(id: "parent")),
                .init(lineIndex: 8, kind: .turnContext),
                .init(lineIndex: 9, kind: .interAgentCommunication(triggerTurn: true)),
            ])

        let suffix = try #require(shape.ownedSuffix)
        #expect(shape.counterSemantics == .copiedPrefix)
        #expect(suffix.startLineIndex == 8)
        #expect(suffix.rawTotalsBaseline.input == 1000)
        #expect(suffix.rawTotalsBaseline.cached == 900)
        #expect(suffix.rawTotalsBaseline.output == 100)
    }

    @Test
    func `nonadjacent trigger does not invent an owned suffix`() {
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(
                    lineIndex: 0,
                    kind: .tokenCount(
                        total: .init(input: 1000, cached: 900, output: 100),
                        last: nil)),
                .init(lineIndex: 1, kind: .sessionMetadata(id: "parent")),
                .init(lineIndex: 3, kind: .turnContext),
                .init(lineIndex: 5, kind: .interAgentCommunication(triggerTurn: true)),
            ])

        #expect(shape.counterSemantics == .copiedPrefix)
        #expect(shape.ownedSuffix == nil)
    }

    @Test
    func `copied prefix can restart only with strong reset evidence`() throws {
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(
                    lineIndex: 2,
                    kind: .tokenCount(
                        total: .init(input: 1000, cached: 900, output: 100),
                        last: nil)),
                .init(lineIndex: 3, kind: .sessionMetadata(id: "parent")),
                .init(lineIndex: 5, kind: .turnContext),
                .init(lineIndex: 6, kind: .interAgentCommunication(triggerTurn: true)),
                .init(
                    lineIndex: 7,
                    kind: .tokenCount(
                        total: .init(input: 50, cached: 10, output: 5),
                        last: .init(input: 50, cached: 10, output: 5))),
            ])

        let suffix = try #require(shape.ownedSuffix)
        #expect(suffix.rawTotalsBaseline.input == 0)
        #expect(suffix.rawTotalsBaseline.cached == 0)
        #expect(suffix.rawTotalsBaseline.output == 0)
    }

    @Test
    func `first valid leaf marker owns later leaf turns`() throws {
        let firstBaseline = CostUsageCodexTotals(input: 1000, cached: 900, output: 100)
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .sessionMetadata(id: "parent")),
                .init(lineIndex: 2, kind: .tokenCount(total: firstBaseline, last: nil)),
                .init(lineIndex: 4, kind: .turnContext),
                .init(lineIndex: 5, kind: .interAgentCommunication(triggerTurn: true)),
                .init(
                    lineIndex: 6,
                    kind: .tokenCount(
                        total: .init(input: 1050, cached: 910, output: 105),
                        last: nil)),
                .init(lineIndex: 8, kind: .turnContext),
                .init(lineIndex: 9, kind: .interAgentCommunication(triggerTurn: true)),
            ])

        let suffix = try #require(shape.ownedSuffix)
        #expect(suffix.startLineIndex == 4)
        #expect(suffix.rawTotalsBaseline.input == firstBaseline.input)
    }

    @Test
    func `later ancestor invalidates a tentative marker`() throws {
        let shape = CostUsageScanner.CodexSubagentRolloutShape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .sessionMetadata(id: "parent")),
                .init(
                    lineIndex: 2,
                    kind: .tokenCount(
                        total: .init(input: 1000, cached: 900, output: 100),
                        last: nil)),
                .init(lineIndex: 3, kind: .turnContext),
                .init(lineIndex: 4, kind: .interAgentCommunication(triggerTurn: true)),
                .init(lineIndex: 5, kind: .sessionMetadata(id: "grandparent")),
                .init(
                    lineIndex: 6,
                    kind: .tokenCount(
                        total: .init(input: 2000, cached: 1800, output: 200),
                        last: nil)),
                .init(lineIndex: 8, kind: .turnContext),
                .init(lineIndex: 9, kind: .interAgentCommunication(triggerTurn: true)),
            ])

        let suffix = try #require(shape.ownedSuffix)
        #expect(suffix.startLineIndex == 8)
        #expect(suffix.rawTotalsBaseline.input == 2000)
    }
}
