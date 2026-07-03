import CodexBarCore
import Testing
@testable import CodexBar

struct MenuOpenRefreshPlanTests {
    @Test
    func `refresh all selects every enabled provider concurrently`() {
        let plan = MenuOpenRefreshPlan.resolve(.init(
            refreshAllOnOpen: true,
            enabledProviders: [.codex, .claude, .factory],
            visibleProviders: [.codex],
            refreshingProviders: [],
            staleProviders: [],
            missingProviders: []))

        #expect(plan.providers == [.codex, .claude, .factory])
        #expect(plan.scheduling == .concurrent)
        #expect(plan.refreshCodexDashboard)
    }

    @Test
    func `refresh all skips dashboard refresh when codex is disabled`() {
        let plan = MenuOpenRefreshPlan.resolve(.init(
            refreshAllOnOpen: true,
            enabledProviders: [.claude, .factory],
            visibleProviders: [.claude],
            refreshingProviders: [],
            staleProviders: [],
            missingProviders: []))

        #expect(plan.providers == [.claude, .factory])
        #expect(!plan.refreshCodexDashboard)
    }

    @Test
    func `ordinary refresh selects only visible enabled retries sequentially`() {
        let plan = MenuOpenRefreshPlan.resolve(.init(
            refreshAllOnOpen: false,
            enabledProviders: [.codex, .claude, .factory],
            visibleProviders: [.factory, .codex, .claude, .cursor],
            refreshingProviders: [.factory],
            staleProviders: [.codex],
            missingProviders: [.claude, .cursor]))

        #expect(plan.providers == [.factory, .codex, .claude])
        #expect(plan.scheduling == .sequential)
        #expect(!plan.refreshCodexDashboard)
    }

    @Test
    func `ordinary refresh skips fresh providers`() {
        let plan = MenuOpenRefreshPlan.resolve(.init(
            refreshAllOnOpen: false,
            enabledProviders: [.codex],
            visibleProviders: [.codex],
            refreshingProviders: [],
            staleProviders: [],
            missingProviders: []))

        #expect(plan.providers.isEmpty)
    }
}
