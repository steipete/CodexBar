import AppKit
import Testing
@testable import CodexBar

@MainActor
struct AccountSegmentedSwitcherViewTests {
    private func segment(_ id: String, system: Bool = false, minimumTitle: String? = nil) -> AccountSwitcherSegment {
        AccountSwitcherSegment(
            id: id,
            fullLabel: "Account \(id)",
            isSystem: system,
            title: { width, measure in
                SwitcherTitleFitting.truncateTail("Account \(id)", toFit: width, measure: measure)
            },
            minimumTitle: minimumTitle)
    }

    @Test
    func `three accounts use one row and four use two`() {
        let three = AccountSegmentedSwitcherView(
            segments: ["1", "2", "3"].map { self.segment($0) }, selectedID: "1", width: 320, onSelect: { _ in })
        let four = AccountSegmentedSwitcherView(
            segments: ["1", "2", "3", "4"].map { self.segment($0) }, selectedID: "1", width: 320, onSelect: { _ in })
        #expect(three.intrinsicContentSize.height == 26)
        #expect(four.intrinsicContentSize.height == 56)
    }

    @Test
    func `system marker prefixes only the system segment`() {
        let view = AccountSegmentedSwitcherView(
            segments: [self.segment("1"), self.segment("2", system: true)],
            selectedID: "1",
            width: 320,
            onSelect: { _ in })
        #expect(view._test_buttonTitles() == ["Account 1", "● Account 2"])
    }

    @Test
    func `tooltips name system and selected state`() {
        let view = AccountSegmentedSwitcherView(
            segments: [self.segment("1"), self.segment("2", system: true)],
            selectedID: "1",
            width: 320,
            onSelect: { _ in })
        #expect(view._test_buttonToolTips() == ["Account 1 — Selected", "Account 2 — System"])
    }

    @Test
    func `clicking a segment selects it and reports its id`() {
        var selected: [String] = []
        let view = AccountSegmentedSwitcherView(
            segments: [self.segment("1"), self.segment("2")],
            selectedID: "1",
            width: 320,
            onSelect: { selected.append($0) })
        #expect(view._test_simulateRuntimeClick(id: "2"))
        #expect(selected == ["2"])
        #expect(view._test_selectedTitles == ["Account 2"])
        #expect(view._test_buttonToolTips() == ["Account 1", "Account 2 — Selected"])
    }

    @Test
    func `nil selection highlights nothing`() {
        let view = AccountSegmentedSwitcherView(
            segments: [self.segment("1"), self.segment("2")], selectedID: nil, width: 320, onSelect: { _ in })
        #expect(view._test_selectedTitles.isEmpty)
    }

    @Test
    func `wide minimum titles reduce the column count`() {
        let wide = String(repeating: "W", count: 30)
        let view = AccountSegmentedSwitcherView(
            segments: ["1", "2", "3"].map { self.segment($0, minimumTitle: wide) },
            selectedID: "1",
            width: 320,
            onSelect: { _ in })
        #expect(view.intrinsicContentSize.height > 26)
    }

    @Test
    func `hit testing routes child buttons to the switcher`() {
        let view = AccountSegmentedSwitcherView(
            segments: [self.segment("1"), self.segment("2")], selectedID: "1", width: 320, onSelect: { _ in })
        #expect(view._test_hitTestSwallowsChildButton(id: "2"))
        #expect(view._test_toolTipAfterHitTest(id: "2") == "Account 2")
    }

    @Test
    func `truncation helpers fit the measured width`() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) }
        #expect(SwitcherTitleFitting.truncateTail("abcdefgh", toFit: 5, measure: measure) == "abcd…")
        #expect(SwitcherTitleFitting.truncateMiddle("abcdefgh", toFit: 5, measure: measure) == "ab…gh")
        #expect(SwitcherTitleFitting.truncateTail("abc", toFit: 5, measure: measure) == "abc")
    }
}
