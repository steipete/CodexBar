import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct PluginMenuBarLayoutTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `plugin projection keeps identity labels extras and reset fallback in its own snapshot`() throws {
        let id = try #require(ProviderInstanceID(rawValue: "layout-example"))
        let snapshot = self.snapshot()
        let data = MenuBarLayoutRenderData.plugin(
            instanceID: id,
            name: "Example",
            snapshot: snapshot,
            iconKey: "fixture",
            hidePersonalInfo: false)
        #expect(data.provider == id)
        #expect(data.descriptor == nil)
        #expect(data.providerName == "Example")
        #expect(data.accountLabel == nil)
        #expect(data.laneLabels.primary == "Requests")
        #expect(data.laneLabels.secondary == "Weekly pool")
        #expect(data.extraTitle("monthly") == "Monthly pool")
        #expect(data.extraTitle("missing") == nil)
        #expect(data.extraWindow("reset-only") == nil)
        #expect(data.automatic == data.weekly)
        #expect(data.balance == nil)
        #expect(MenuBarLayoutResetText(
            window: data.primary,
            provider: id,
            now: self.now,
            absolute: false).value == "Tomorrow")
        let foreign = UsageSnapshot(
            primary: snapshot.primary,
            secondary: nil,
            updatedAt: self.now,
            identity: ProviderIdentitySnapshot(
                providerID: .codex, accountEmail: "foreign@example.test", accountOrganization: nil, loginMethod: nil))
        #expect(MenuBarLayoutRenderData.plugin(
            instanceID: id,
            name: "Example",
            snapshot: foreign,
            iconKey: "fixture",
            hidePersonalInfo: false)
            .accountLabel == nil)
    }

    @Test
    func `plugin layout honors order separators named windows and conditional branches`() throws {
        let id = try #require(ProviderInstanceID(rawValue: "layout-example"))
        let data = MenuBarLayoutRenderData.plugin(
            instanceID: id,
            name: "Example",
            snapshot: self.snapshot(),
            iconKey: "fixture",
            hidePersonalInfo: true)
        let conditional = MenuBarLayoutConditional(
            clauses: [.init(combinator: nil, predicate: .init(
                metric: .secondaryLane, comparison: .greaterThan, threshold: 50))],
            thenToken: .extraPercent(id: "monthly"),
            elseToken: .hidden)
        let layout = MenuBarLayout(lines: [[
            .providerName, .separator(.pipe), .percent(window: .session), .separator(.slash),
            .conditional(id: conditional.id), .separatorDot, .windowResetCountdown(window: .weekly),
        ]])
        let renderer = MenuBarLayoutRenderer()
        let rendered = renderer.render(layout: layout, data: data, icon: nil, options: self.options([conditional]))
        #expect(rendered.attributedTitle.string.replacingOccurrences(of: "\u{2009}", with: " ")
            .contains("Example | R 37% / Monthly pool 81%"))
        #expect(rendered.attributedTitle.string.contains("in 1h"))
        #expect(rendered.accessibilityLabel.contains("Requests"))
        #expect(rendered.accessibilityLabel.contains("Weekly pool"))
        let repeated = renderer.render(layout: layout, data: data, icon: nil, options: self.options([conditional]))
        #expect(rendered.attributedTitle === repeated.attributedTitle)
        let changed = MenuBarLayoutRenderData.plugin(
            instanceID: id,
            name: "Example",
            snapshot: self.snapshot(weekly: 40),
            iconKey: "fixture",
            hidePersonalInfo: true)
        let hidden = renderer.render(layout: layout, data: changed, icon: nil, options: self.options([conditional]))
        #expect(!hidden.attributedTitle.string.contains("Monthly pool"))
    }

    @Test
    func `plugin render data ignores fetch timestamps but invalidates reset changes`() throws {
        let id = try #require(ProviderInstanceID(rawValue: "layout-example"))
        func data(reset: Date, updatedAt: Date) -> MenuBarLayoutRenderData {
            let snapshot = UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: reset, resetDescription: nil),
                secondary: nil,
                updatedAt: updatedAt)
            return .plugin(
                instanceID: id,
                name: "Example",
                snapshot: snapshot,
                iconKey: "fixture",
                hidePersonalInfo: true)
        }
        let reset = self.now.addingTimeInterval(3650)
        let initial = data(reset: reset, updatedAt: self.now)
        #expect(initial == data(reset: reset, updatedAt: self.now.addingTimeInterval(10)))
        #expect(initial != data(reset: reset.addingTimeInterval(3600), updatedAt: self.now))
    }

    @Test
    func `missing plugin metric falls back to automatic without inventing a reset`() throws {
        let id = try #require(ProviderInstanceID(rawValue: "layout-example"))
        let data = MenuBarLayoutRenderData.plugin(
            instanceID: id,
            name: "Example",
            snapshot: self.snapshot(),
            iconKey: "fixture",
            hidePersonalInfo: true)
        let output = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.lanePercent(lane: .tertiary), .extraPercent(id: "gone")]]),
            data: data,
            icon: nil,
            options: self.options())
        #expect(output.attributedTitle.string.contains("62%"))
        #expect(data.tertiary == nil)
        #expect(data.extraWindow("gone") == nil)
        let scoped = MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.percent(window: .scopedWeekly)]]),
            data: data,
            icon: nil,
            options: self.options())
        #expect(scoped.attributedTitle.string == "–")
    }

    private func snapshot(weekly: Double = 62) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 37,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "Tomorrow",
                title: "Requests"),
            secondary: RateWindow(
                usedPercent: weekly,
                windowMinutes: 10080,
                resetsAt: self.now.addingTimeInterval(3650),
                resetDescription: nil,
                title: "Weekly pool"),
            extraRateWindows: [
                NamedRateWindow(
                    id: "monthly",
                    title: "Monthly pool",
                    window: RateWindow(usedPercent: 81, windowMinutes: 43200, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "reset-only",
                    title: "Reset only",
                    window: RateWindow(usedPercent: 0, windowMinutes: 60, resetsAt: self.now, resetDescription: nil),
                    usageKnown: false),
            ],
            updatedAt: self.now)
    }

    private func options(_ conditionals: [MenuBarLayoutConditional] = []) -> MenuBarLayoutRenderOptions {
        MenuBarLayoutRenderOptions(
            size: .regular,
            highContrast: false,
            showUsed: true,
            conditionals: conditionals,
            appearanceName: "NSAppearanceNameAqua",
            isDebugApp: false,
            now: self.now)
    }
}
