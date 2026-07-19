import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CodexBar

struct MenuBarLayoutEditorTests {
    @Test
    func `palette tokens append and insert at a drop index`() {
        let initial = MenuBarLayout(lines: [[.icon, .resetCountdown]])

        let appended = MenuBarLayoutEditorMutations.append(.space, to: initial)
        #expect(appended.lines == [[.icon, .resetCountdown, .space]])

        let inserted = MenuBarLayoutEditorMutations.insert(
            .palette(.percent(window: .weekly)),
            at: MenuBarLayoutPosition(line: 0, index: 1),
            in: initial)
        #expect(inserted.lines == [[.icon, .percent(window: .weekly), .resetCountdown]])
    }

    @Test
    func `dragging within a line reorders without duplicating`() {
        let initial = MenuBarLayout(lines: [[.icon, .providerName, .resetCountdown]])
        let dragged = MenuBarLayoutDragItem.placed(
            .icon,
            at: MenuBarLayoutPosition(line: 0, index: 0),
            in: initial)

        let reordered = MenuBarLayoutEditorMutations.insert(
            dragged,
            at: MenuBarLayoutPosition(line: 0, index: 3),
            in: initial)

        #expect(reordered.lines == [[.providerName, .resetCountdown, .icon]])

        let unchanged = MenuBarLayoutEditorMutations.insert(
            .placed(.providerName, at: MenuBarLayoutPosition(line: 0, index: 1), in: initial),
            at: MenuBarLayoutPosition(line: 0, index: 1),
            in: initial)
        #expect(unchanged == initial)
    }

    @Test
    func `dragging between lines moves the token`() {
        let initial = MenuBarLayout(lines: [[.icon, .providerName], [.percent(window: .weekly)]])
        let dragged = MenuBarLayoutDragItem.placed(
            .providerName,
            at: MenuBarLayoutPosition(line: 0, index: 1),
            in: initial)

        let reordered = MenuBarLayoutEditorMutations.insert(
            dragged,
            at: MenuBarLayoutPosition(line: 1, index: 0),
            in: initial)

        #expect(reordered.lines == [[.icon], [.providerName, .percent(window: .weekly)]])
    }

    @Test
    func `stale drag source leaves the layout unchanged`() {
        let initial = MenuBarLayout(lines: [[.icon, .providerName]])
        let stale = MenuBarLayoutDragItem.placed(
            .icon,
            at: MenuBarLayoutPosition(line: 0, index: 1),
            in: initial)

        let result = MenuBarLayoutEditorMutations.insert(
            stale,
            at: MenuBarLayoutPosition(line: 0, index: 2),
            in: initial)

        #expect(result == initial)
    }

    @Test
    func `line break splits and rejoins the strip`() {
        let initial = MenuBarLayout(lines: [[.icon, .providerName, .percent(window: .automatic)]])

        let split = MenuBarLayoutEditorMutations.addLineBreak(to: initial, at: 2)
        #expect(split.lines == [[.icon, .providerName], [.percent(window: .automatic)]])
        #expect(MenuBarLayoutEditorMutations.removeLineBreak(from: split) == initial)
    }

    @Test
    func `line break preserves an empty second line until a token is dropped`() {
        let initial = MenuBarLayout(lines: [[.icon]])
        let split = MenuBarLayoutEditorMutations.addLineBreak(to: initial)
        #expect(split.lines == [[.icon], []])

        let inserted = MenuBarLayoutEditorMutations.insert(
            .palette(.percent(window: .session)),
            at: MenuBarLayoutPosition(line: 1, index: 0),
            in: split)
        #expect(inserted.lines == [[.icon], [.percent(window: .session)]])
    }

    @Test
    func `delete and drag out keep at least one token`() {
        let initial = MenuBarLayout(lines: [[.icon, .providerName]])
        let deleted = MenuBarLayoutEditorMutations.remove(
            at: MenuBarLayoutPosition(line: 0, index: 0),
            from: initial)
        #expect(deleted.lines == [[.providerName]])

        let lastToken = MenuBarLayoutDragItem.placed(
            .providerName,
            at: MenuBarLayoutPosition(line: 0, index: 0),
            in: deleted)
        #expect(MenuBarLayoutEditorMutations.remove(lastToken, from: deleted) == deleted)

        let staleToken = MenuBarLayoutDragItem.placed(
            .icon,
            at: MenuBarLayoutPosition(line: 0, index: 1),
            in: initial)
        #expect(MenuBarLayoutEditorMutations.remove(staleToken, from: initial) == initial)

        let changedDuringDrag = MenuBarLayout(lines: [[.icon, .resetCountdown]])
        let oldPayload = MenuBarLayoutDragItem.placed(
            .icon,
            at: MenuBarLayoutPosition(line: 0, index: 0),
            in: initial)
        #expect(MenuBarLayoutEditorMutations.remove(oldPayload, from: changedDuringDrag) == changedDuringDrag)

        let iconAndSpace = MenuBarLayout(lines: [[.icon, .space]])
        #expect(MenuBarLayoutEditorMutations.remove(
            at: MenuBarLayoutPosition(line: 0, index: 0),
            from: iconAndSpace) == iconAndSpace)
    }

    @Test
    func `drag payload codable round trips`() throws {
        let layout = MenuBarLayout(lines: [[.icon], [.providerName, .space, .percent(window: .automatic)]])
        let payload = MenuBarLayoutDragItem.placed(
            .percent(window: .automatic),
            at: MenuBarLayoutPosition(line: 1, index: 2),
            in: layout)

        let data = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(MenuBarLayoutDragItem.self, from: data) == payload)
    }

    @Test
    @available(macOS 15.2, *)
    func `palette drag transfer representation round trips`() async throws {
        let payload = MenuBarLayoutDragItem.palette(.percent(window: .weekly))

        #expect(MenuBarLayoutDragItem.exportedContentTypes() == [.codexBarMenuLayoutItem])
        #expect(MenuBarLayoutDragItem.importedContentTypes() == [.codexBarMenuLayoutItem])

        let data = try await payload.exported(as: .codexBarMenuLayoutItem)
        let decoded = try await MenuBarLayoutDragItem(
            importing: data,
            contentType: .codexBarMenuLayoutItem)
        #expect(decoded == payload)
    }
}
