import Foundation
import Testing
@testable import CodexBar

// MARK: - PopoverAccountSwitcherView.Segment 基本测试

struct PopoverAccountSwitcherTests {
    // MARK: - Identifiable

    @Test
    func `Segment id is used as Identifiable id`() {
        let seg = PopoverAccountSwitcherView.Segment(id: "abc", title: "Alice", isSelected: false)
        #expect(seg.id == "abc")
    }

    // MARK: - Equatable

    @Test
    func `Segment Equatable: same values are equal`() {
        let a = PopoverAccountSwitcherView.Segment(id: "x", title: "X", isSelected: true)
        let b = PopoverAccountSwitcherView.Segment(id: "x", title: "X", isSelected: true)
        #expect(a == b)
    }

    @Test
    func `Segment Equatable: different id not equal`() {
        let a = PopoverAccountSwitcherView.Segment(id: "x", title: "X", isSelected: false)
        let b = PopoverAccountSwitcherView.Segment(id: "y", title: "X", isSelected: false)
        #expect(a != b)
    }

    @Test
    func `Segment Equatable: different isSelected not equal`() {
        let a = PopoverAccountSwitcherView.Segment(id: "x", title: "X", isSelected: false)
        let b = PopoverAccountSwitcherView.Segment(id: "x", title: "X", isSelected: true)
        #expect(a != b)
    }

    // MARK: - make(ids:titles:selectedID:) isSelected 映射逻辑

    @Test
    func `make: correct isSelected when selectedID matches one id`() {
        let segs = PopoverAccountSwitcherView.Segment.make(
            ids: ["a", "b", "c"],
            titles: ["A", "B", "C"],
            selectedID: "b")
        #expect(segs.count == 3)
        #expect(segs[0].isSelected == false)
        #expect(segs[1].isSelected == true)
        #expect(segs[2].isSelected == false)
    }

    @Test
    func `make: all unselected when selectedID is nil`() {
        let segs = PopoverAccountSwitcherView.Segment.make(
            ids: ["a", "b"],
            titles: ["A", "B"],
            selectedID: nil)
        #expect(segs.allSatisfy { !$0.isSelected })
    }

    @Test
    func `make: all unselected when selectedID does not match any id`() {
        let segs = PopoverAccountSwitcherView.Segment.make(
            ids: ["a", "b"],
            titles: ["A", "B"],
            selectedID: "z")
        #expect(segs.allSatisfy { !$0.isSelected })
    }

    @Test
    func `make: titles are preserved in order`() {
        let segs = PopoverAccountSwitcherView.Segment.make(
            ids: ["1", "2", "3"],
            titles: ["One", "Two", "Three"],
            selectedID: "1")
        #expect(segs.map(\.title) == ["One", "Two", "Three"])
    }

    @Test
    func `make: ids are preserved in order`() {
        let segs = PopoverAccountSwitcherView.Segment.make(
            ids: ["id1", "id2"],
            titles: ["T1", "T2"],
            selectedID: "id1")
        #expect(segs.map(\.id) == ["id1", "id2"])
    }

    @Test
    func `make: empty input produces empty output`() {
        let segs = PopoverAccountSwitcherView.Segment.make(
            ids: [],
            titles: [],
            selectedID: nil)
        #expect(segs.isEmpty)
    }

    @Test
    func `make: first selected when selectedID equals first id`() {
        let segs = PopoverAccountSwitcherView.Segment.make(
            ids: ["0", "1", "2"],
            titles: ["Zero", "One", "Two"],
            selectedID: "0")
        #expect(segs[0].isSelected == true)
        #expect(segs[1].isSelected == false)
        #expect(segs[2].isSelected == false)
    }

    @Test
    func `make: last selected when selectedID equals last id`() {
        let segs = PopoverAccountSwitcherView.Segment.make(
            ids: ["0", "1", "2"],
            titles: ["Zero", "One", "Two"],
            selectedID: "2")
        #expect(segs[0].isSelected == false)
        #expect(segs[1].isSelected == false)
        #expect(segs[2].isSelected == true)
    }

    /// Token 路径：index 字符串 id
    @Test
    func `make: token-style index ids - selectedID maps correctly`() {
        let segs = PopoverAccountSwitcherView.Segment.make(
            ids: ["0", "1", "2"],
            titles: ["Account A", "Account B", "Account C"],
            selectedID: "1")
        #expect(segs[0].isSelected == false)
        #expect(segs[1].isSelected == true)
        #expect(segs[2].isSelected == false)
    }
}

// MARK: - display 依赖重的构造路径说明

//
// popoverAccountSwitcherModel(for:) 内部依赖 StatusItemController（需要完整的
// UsageStore + SettingsStore + 运行时账户状态），构造成本高且非 headless 可用，
// 因此不在单测中覆盖。全量回归（swift test）+ 人工验证（打开 popover、切换账户
// 确认 UI 响应）作为兜底。
