import Testing
@testable import CodexBar

struct CursorLoginAccountSelectorTests {
    @Test
    func `labels include available identity metadata and always include the source`() {
        let choices = CursorLoginAccountSelector.choices(for: [
            .init(
                selectionID: "name-and-email",
                name: "Example Team",
                email: "team@example.com",
                sourceLabel: "Comet · Work"),
            .init(
                selectionID: "email-only",
                name: nil,
                email: "personal@example.com",
                sourceLabel: "Safari"),
            .init(
                selectionID: "source-only",
                name: nil,
                email: nil,
                sourceLabel: "Chrome · Profile 2"),
        ])

        #expect(Set(choices.map(\.displayLabel)) == [
            "Example Team · team@example.com · Comet · Work",
            "personal@example.com · Safari",
            "\(L("Account")) · Chrome · Profile 2",
        ])
    }

    @Test
    func `same email candidates from different sources remain separate choices`() {
        let candidates: [CursorLoginAccountSelector.Candidate] = [
            .init(
                selectionID: "account-comet",
                name: nil,
                email: "same@example.com",
                sourceLabel: "Comet"),
            .init(
                selectionID: "account-safari",
                name: nil,
                email: "same@example.com",
                sourceLabel: "Safari"),
        ]

        let choices = CursorLoginAccountSelector.choices(for: candidates)

        #expect(choices.map(\.selectionID) == ["account-comet", "account-safari"])
        #expect(choices.map(\.displayLabel) == [
            "same@example.com · Comet",
            "same@example.com · Safari",
        ])
    }

    @Test
    func `identical account labels use human ordinals while stable IDs remain mapping only`() {
        let choices = CursorLoginAccountSelector.choices(for: [
            .init(
                selectionID: "stable-b",
                name: nil,
                email: "same@example.com",
                sourceLabel: "Comet"),
            .init(
                selectionID: "stable-a",
                name: nil,
                email: "same@example.com",
                sourceLabel: "Comet"),
        ])

        #expect(choices == [
            .init(selectionID: "stable-a", displayLabel: "same@example.com · Comet · 1"),
            .init(selectionID: "stable-b", displayLabel: "same@example.com · Comet · 2"),
        ])
        #expect(choices.allSatisfy { !$0.displayLabel.contains("stable-") })
    }

    @Test
    func `choice ordering is deterministic regardless of candidate order`() {
        let candidates: [CursorLoginAccountSelector.Candidate] = [
            .init(selectionID: "z", name: "Zed", email: nil, sourceLabel: "Safari"),
            .init(selectionID: "a", name: "Alpha", email: nil, sourceLabel: "Comet"),
        ]

        #expect(CursorLoginAccountSelector.choices(for: candidates) ==
            CursorLoginAccountSelector.choices(for: Array(candidates.reversed())))
    }

    @Test
    func `non UI selection helper maps confirmation and cancellation`() {
        let choices: [CursorLoginAccountSelector.Choice] = [
            .init(selectionID: "first", displayLabel: "First · Safari"),
            .init(selectionID: "second", displayLabel: "Second · Comet"),
        ]

        #expect(CursorLoginAccountSelector.selectedCandidateID(
            from: choices,
            selectedIndex: 1,
            confirmed: true) == "second")
        #expect(CursorLoginAccountSelector.selectedCandidateID(
            from: choices,
            selectedIndex: 1,
            confirmed: false) == nil)
        #expect(CursorLoginAccountSelector.selectedCandidateID(
            from: choices,
            selectedIndex: nil,
            confirmed: true) == nil)
        #expect(CursorLoginAccountSelector.selectedCandidateID(
            from: choices,
            selectedIndex: 2,
            confirmed: true) == nil)
    }

    @Test
    @MainActor
    func `injected chooser maps only a presented stable selection ID`() {
        let candidates: [CursorLoginAccountSelector.Candidate] = [
            .init(selectionID: "first", name: nil, email: "a@example.com", sourceLabel: "Safari"),
            .init(selectionID: "second", name: nil, email: "b@example.com", sourceLabel: "Comet"),
        ]
        var presentedChoices: [CursorLoginAccountSelector.Choice] = []

        let selectedID = CursorLoginAccountSelector.selectCandidateID(from: candidates) {
            presentedChoices = $0
            return "second"
        }
        let cancelledID = CursorLoginAccountSelector.selectCandidateID(from: candidates) { _ in nil }
        let unknownID = CursorLoginAccountSelector.selectCandidateID(from: candidates) { _ in "unknown" }

        #expect(presentedChoices == CursorLoginAccountSelector.choices(for: candidates))
        #expect(selectedID == "second")
        #expect(cancelledID == nil)
        #expect(unknownID == nil)
    }
}
