import CodexBarCore
import CoreTransferable
import Foundation
import Observation
import Testing
import UniformTypeIdentifiers
@testable import CodexBar

struct MenuBarLayoutEditorTests {
    @Test
    @MainActor
    func `all scope discloses only enabled saved overrides in provider order including equal layouts`() throws {
        let settings = try Self.overrideSettings()
        let global = MenuBarLayout(lines: [[.providerName, .percent(window: .session)]])
        settings.setMenuBarLayout(global, for: nil)
        settings.setMenuBarLayout(global, for: .cursor)
        settings.setMenuBarLayout(MenuBarLayout(lines: [[.percent(window: .weekly)]]), for: .claude)
        settings.setMenuBarLayout(global, for: .codex)

        #expect(MenuBarLayoutEditorScope.all.providersWithOverrides(settings: settings) == [.claude, .cursor])
        #expect(MenuBarLayoutEditorScope.provider(.claude).providersWithOverrides(settings: settings).isEmpty)
        #expect(MenuBarLayoutEditorScope.all.previewLabel == L("menu_bar_layout_default_preview"))
        #expect(MenuBarLayoutEditorScope.provider(.claude).previewLabel == L("menu_bar_layout_live_preview"))
    }

    @Test
    @MainActor
    func `editor reset removes only its enabled provider and updates observed disclosure`() throws {
        let settings = try Self.overrideSettings()
        let global = MenuBarLayout(lines: [[.providerName]])
        let override = MenuBarLayout(lines: [[.percent(window: .weekly)]])
        settings.setMenuBarLayout(global, for: nil)
        settings.setMenuBarLayout(override, for: .claude)
        settings.setMenuBarLayout(global, for: .cursor)
        settings.setMenuBarLayout(override, for: .codex)
        let changed = LockIsolated(false)
        withObservationTracking {
            _ = MenuBarLayoutEditorScope.all.providersWithOverrides(settings: settings)
        } onChange: {
            changed.setValue(true)
        }

        MenuBarLayoutEditorPersistence.useAllProvidersLayout(for: .claude, settings: settings)

        #expect(changed.value)
        #expect(settings.menuBarLayout(for: .claude) == global)
        #expect(settings.menuBarLayoutOverrides == [.cursor: global, .codex: override])
        #expect(MenuBarLayoutEditorScope.all.providersWithOverrides(settings: settings) == [.cursor])

        MenuBarLayoutEditorPersistence.useAllProvidersLayout(for: .cursor, settings: settings)
        #expect(MenuBarLayoutEditorScope.all.providersWithOverrides(settings: settings).isEmpty)
        #expect(settings.menuBarLayoutOverrides == [.codex: override])
    }

    @Test
    @MainActor
    func `editor reset leaves disabled and no longer enabled providers untouched`() throws {
        let settings = try Self.overrideSettings()
        let override = MenuBarLayout(lines: [[.percent(window: .weekly)]])
        settings.setMenuBarLayout(override, for: .claude)
        settings.setMenuBarLayout(override, for: .codex)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: false)

        MenuBarLayoutEditorPersistence.useAllProvidersLayout(for: .claude, settings: settings)
        MenuBarLayoutEditorPersistence.useAllProvidersLayout(for: .codex, settings: settings)
        MenuBarLayoutEditorPersistence.useAllProvidersLayout(for: .cursor, settings: settings)

        #expect(MenuBarLayoutEditorScope.all.providersWithOverrides(settings: settings).isEmpty)
        #expect(settings.menuBarLayoutOverrides == [.claude: override, .codex: override])
        #expect(!settings.hasStoredMenuBarLayout)
        #expect(settings.providerEnablement[.claude] == false)
        #expect(settings.providerEnablement[.codex] == false)
    }

    @MainActor
    private static func overrideSettings() throws -> SettingsStore {
        try #require(SettingsStore.isRunningTests)
        let enabled: [UsageProvider] = [.claude, .cursor, .kimi]
        let order = enabled + UsageProvider.allCases.filter { !enabled.contains($0) }
        return testSettingsStore(
            suiteName: "MenuBarLayoutEditorTests-overrides",
            config: CodexBarConfig(providers: order.map {
                ProviderConfig(id: $0.instanceID, enabled: enabled.contains($0))
            }),
            prepareDefaults: { defaults in
                defaults.set(AppGroupSupport.migrationVersion, forKey: AppGroupSupport.migrationVersionKey)
                defaults.set(true, forKey: "debugDisableKeychainAccess")
            })
    }

    @Test
    func `time palette lists the compact run out token with a clear label`() {
        #expect(MenuBarLayoutPaletteTokens.time.contains(.runsOutCompact))
        #expect(MenuBarLayoutToken.runsOutCompact.editorLabel(provider: .codex) == "Runs out (compact)")
    }

    @Test
    func `Notion secondary editor labels use monthly cadence`() {
        let percent = MenuBarLayoutToken.percent(window: .weekly)
        let pace = MenuBarLayoutToken.pace(window: .weekly)
        let monthlyPace = L("%@ %@", L("Monthly"), L("display_mode_pace").lowercased())

        #expect(percent.editorLabel(provider: .notion) == L("%@ %@", L("Monthly"), "%"))
        #expect(pace.editorLabel(provider: .notion) == monthlyPace)
        #expect(pace.editorAccessibilityLabel(provider: .notion) == monthlyPace)
        #expect(percent.editorLabel(provider: .codex) == L("menu_bar_layout_token_weekly"))
        #expect(pace.editorLabel(provider: .codex) == L("menu_bar_layout_token_weekly_pace"))
    }

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
        let layout = MenuBarLayout(lines: [[.icon, .balance], [.providerName, .space, .percent(window: .automatic)]])
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
        let payload = MenuBarLayoutDragItem.palette(.percent(window: .scopedWeekly))

        #expect(MenuBarLayoutDragItem.exportedContentTypes() == [.codexBarMenuLayoutItem])
        #expect(MenuBarLayoutDragItem.importedContentTypes() == [.codexBarMenuLayoutItem])

        let data = try await payload.exported(as: .codexBarMenuLayoutItem)
        let decoded = try await MenuBarLayoutDragItem(
            importing: data,
            contentType: .codexBarMenuLayoutItem)
        #expect(decoded == payload)
    }

    @Test
    func `conditional drag payload round trips`() throws {
        let payload = MenuBarLayoutDragItem.palette(.conditional(id: UUID()))

        let data = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(MenuBarLayoutDragItem.self, from: data) == payload)
    }

    @Test
    func `conditional token appends like palette tokens`() {
        let initial = MenuBarLayout(lines: [[.icon, .resetCountdown]])
        let conditionalID = UUID()

        let appended = MenuBarLayoutEditorMutations.append(
            .conditional(id: conditionalID),
            to: initial)
        #expect(appended.lines == [[.icon, .resetCountdown, .conditional(id: conditionalID)]])
    }

    @Test
    func `balance token is provider aware`() throws {
        let row = try ProviderDetailSection.Row(label: "Remaining", value: "$12.34")
        let section = try ProviderDetailSection(title: "Credits", rows: [row])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [section],
            updatedAt: Date())

        #expect(MenuBarLayoutBalanceResolver.balance(provider: .openrouter, snapshot: snapshot) == "$12.34")
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .codex, snapshot: snapshot) == nil)
        #expect(MenuBarLayoutToken.balance.editorLabel(provider: .openrouter) == L("Balance"))
    }

    @Test
    func `conditional palette chips wrap instead of overflowing the pane`() {
        let spacing: CGFloat = 6

        // Two 100pt chips fit in 220pt (100 + 6 + 100); the third has to wrap.
        #expect(MenuBarLayoutChipFlowLayout.rows(
            widths: [100, 100, 100],
            maxWidth: 220,
            spacing: spacing) == [[0, 1], [2]])

        // Long localized names still get placed on their own row rather than dropped.
        #expect(MenuBarLayoutChipFlowLayout.rows(
            widths: [400],
            maxWidth: 220,
            spacing: spacing) == [[0]])
        #expect(MenuBarLayoutChipFlowLayout.rows(
            widths: [400, 120],
            maxWidth: 220,
            spacing: spacing) == [[0], [1]])

        // Chips that fit stay on one row, so a short library keeps hugging the leading edge.
        #expect(MenuBarLayoutChipFlowLayout.rows(
            widths: [80, 90],
            maxWidth: 220,
            spacing: spacing) == [[0, 1]])
    }
}
