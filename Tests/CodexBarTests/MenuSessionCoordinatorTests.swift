import Testing
@testable import CodexBar

struct MenuSessionCoordinatorTests {
    @Test
    func `invalidation records data structural and required generations independently`() {
        var coordinator = MenuSessionCoordinator<String>()

        coordinator.invalidate(allowsStaleContent: false, requiresRebuild: true)
        #expect(coordinator.contentVersion == 1)
        #expect(coordinator.latestStructuralContentVersion == 1)
        #expect(coordinator.latestRequiredRebuildVersion == 1)
        #expect(coordinator.latestDataOnlyContentVersion == 0)

        coordinator.invalidate(allowsStaleContent: true, requiresRebuild: false)
        #expect(coordinator.contentVersion == 2)
        #expect(coordinator.latestDataOnlyContentVersion == 2)
        #expect(coordinator.latestStructuralContentVersion == 1)
        #expect(coordinator.latestRequiredRebuildVersion == 1)

        coordinator.invalidate(allowsStaleContent: false, requiresRebuild: false)
        #expect(coordinator.contentVersion == 3)
        #expect(coordinator.latestStructuralContentVersion == 3)
        #expect(coordinator.latestRequiredRebuildVersion == 1)
    }

    @Test
    func `closed preparation distinguishes no work deferred work and required work`() {
        var coordinator = MenuSessionCoordinator<String>()
        let menu = "menu"

        #expect(coordinator.closedPreparationPlan(for: [menu]) == .nonDeferred)

        coordinator.invalidate(allowsStaleContent: true, requiresRebuild: false)
        #expect(coordinator.closedPreparationPlan(for: [menu]) == .none)

        coordinator.invalidate(allowsStaleContent: false, requiresRebuild: true)
        #expect(coordinator.closedPreparationPlan(for: [menu]) == .required(version: 2))

        coordinator.markFresh(menu)
        #expect(coordinator.closedPreparationPlan(for: [menu]) == .nonDeferred)
    }

    @Test
    func `stale content survives only a data generation after latest structural render`() {
        var coordinator = MenuSessionCoordinator<String>()
        let menu = "menu"

        coordinator.invalidate(allowsStaleContent: false, requiresRebuild: true)
        coordinator.markFresh(menu)
        coordinator.invalidate(allowsStaleContent: true, requiresRebuild: false)
        #expect(coordinator.canPreserveStaleContent(for: menu))

        coordinator.invalidate(allowsStaleContent: false, requiresRebuild: false)
        coordinator.invalidate(allowsStaleContent: true, requiresRebuild: false)
        #expect(!coordinator.canPreserveStaleContent(for: menu))
    }

    @Test
    func `removing menu clears all menu scoped lifecycle state`() {
        var coordinator = MenuSessionCoordinator<String>()
        let menu = "menu"

        coordinator.markFresh(menu)
        coordinator.deferUntilNextOpen(menu)
        coordinator.deferParentRebuild(menu)
        coordinator.removeMenu(menu)

        #expect(coordinator.renderedVersion(for: menu) == nil)
        #expect(!coordinator.isDeferredUntilNextOpen(menu))
        #expect(!coordinator.isParentRebuildDeferred(menu))
    }
}

struct MenuRebuildRequestRegistryTests {
    @Test
    func `replacement request invalidates prior token without affecting other menus`() {
        var registry = MenuRebuildRequestRegistry<String>()

        let first = registry.replaceRequest(for: "parent")
        let child = registry.replaceRequest(for: "child")
        let replacement = registry.replaceRequest(for: "parent")

        #expect(!registry.isCurrent(first, for: "parent"))
        #expect(registry.isCurrent(replacement, for: "parent"))
        #expect(registry.isCurrent(child, for: "child"))
    }

    @Test
    func `stale completion cannot clear replacement request`() {
        var registry = MenuRebuildRequestRegistry<String>()
        let stale = registry.replaceRequest(for: "menu")
        let current = registry.replaceRequest(for: "menu")

        let staleDidFinish = registry.finish(stale, for: "menu")
        #expect(!staleDidFinish)
        #expect(registry.isCurrent(current, for: "menu"))
        let currentDidFinish = registry.finish(current, for: "menu")
        #expect(currentDidFinish)
        #expect(!registry.isCurrent(current, for: "menu"))
    }

    @Test
    func `cancelling all requests keeps future tokens distinct`() {
        var registry = MenuRebuildRequestRegistry<String>()
        let cancelled = registry.replaceRequest(for: "menu")

        registry.cancelAll()
        let replacement = registry.replaceRequest(for: "menu")

        #expect(cancelled != replacement)
        #expect(registry.isCurrent(replacement, for: "menu"))
    }
}
