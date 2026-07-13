struct MenuSessionCoordinator<MenuID: Hashable> {
    enum ClosedPreparationPlan: Equatable {
        case none
        case nonDeferred
        case required(version: Int)
    }

    private(set) var contentVersion = 0
    private(set) var latestRequiredRebuildVersion = 0
    private(set) var latestDataOnlyContentVersion = 0
    private(set) var latestStructuralContentVersion = 0
    private(set) var renderedVersions: [MenuID: Int] = [:]
    private(set) var deferredUntilNextOpen: Set<MenuID> = []
    private(set) var parentRebuildsDeferredDuringTracking: Set<MenuID> = []
    private var nextMenuInteractionGeneration = 0
    private(set) var menuInteractionGenerations: [MenuID: Int] = [:]
    private var nextViewportRestoreGeneration = 0
    private(set) var pendingViewportRestores: [MenuID: Int] = [:]

    @discardableResult
    mutating func invalidate(
        allowsStaleContent: Bool,
        requiresRebuild: Bool)
        -> Int
    {
        self.contentVersion &+= 1
        if allowsStaleContent {
            self.latestDataOnlyContentVersion = self.contentVersion
        } else {
            self.latestStructuralContentVersion = self.contentVersion
            if requiresRebuild {
                self.latestRequiredRebuildVersion = self.contentVersion
            }
        }
        return self.contentVersion
    }

    func needsRefresh(_ menuID: MenuID) -> Bool {
        self.renderedVersions[menuID] != self.contentVersion
    }

    mutating func markFresh(_ menuID: MenuID) {
        self.renderedVersions[menuID] = self.contentVersion
    }

    func renderedVersion(for menuID: MenuID) -> Int? {
        self.renderedVersions[menuID]
    }

    func canPreserveStaleContent(for menuID: MenuID) -> Bool {
        guard let renderedVersion = self.renderedVersions[menuID] else { return false }
        return self.contentVersion == self.latestDataOnlyContentVersion &&
            renderedVersion >= self.latestStructuralContentVersion
    }

    func hasRequiredClosedPreparation(for menuIDs: some Sequence<MenuID>) -> Bool {
        guard self.latestRequiredRebuildVersion > 0 else { return false }
        return menuIDs.contains { self.isRenderedVersion($0, olderThan: self.latestRequiredRebuildVersion) }
    }

    func closedPreparationPlan(for menuIDs: some Sequence<MenuID>) -> ClosedPreparationPlan {
        if self.hasRequiredClosedPreparation(for: menuIDs) {
            return .required(version: self.latestRequiredRebuildVersion)
        }
        if self.contentVersion > self.latestRequiredRebuildVersion {
            return .none
        }
        return .nonDeferred
    }

    func isRenderedVersion(_ menuID: MenuID, olderThan version: Int) -> Bool {
        (self.renderedVersions[menuID] ?? -1) < version
    }

    mutating func deferUntilNextOpen(_ menuID: MenuID) {
        self.deferredUntilNextOpen.insert(menuID)
    }

    mutating func clearNextOpenDeferral(_ menuID: MenuID) {
        self.deferredUntilNextOpen.remove(menuID)
    }

    func isDeferredUntilNextOpen(_ menuID: MenuID) -> Bool {
        self.deferredUntilNextOpen.contains(menuID)
    }

    mutating func deferParentRebuild(_ menuID: MenuID) {
        self.parentRebuildsDeferredDuringTracking.insert(menuID)
    }

    mutating func clearParentRebuildDeferral(_ menuID: MenuID) {
        self.parentRebuildsDeferredDuringTracking.remove(menuID)
    }

    func isParentRebuildDeferred(_ menuID: MenuID) -> Bool {
        self.parentRebuildsDeferredDuringTracking.contains(menuID)
    }

    /// Identifies one concrete open/close lifetime even when AppKit reuses the same menu object.
    @discardableResult
    mutating func beginTrackingSession(_ menuID: MenuID) -> Int {
        self.replaceMenuInteractionGeneration(for: menuID)
    }

    func menuInteractionGeneration(for menuID: MenuID) -> Int? {
        self.menuInteractionGenerations[menuID]
    }

    func isCurrentMenuInteraction(_ generation: Int, for menuID: MenuID) -> Bool {
        self.menuInteractionGenerations[menuID] == generation
    }

    @discardableResult
    mutating func advanceMenuInteraction(for menuID: MenuID) -> Int? {
        guard self.menuInteractionGenerations[menuID] != nil else { return nil }
        return self.replaceMenuInteractionGeneration(for: menuID)
    }

    private mutating func replaceMenuInteractionGeneration(for menuID: MenuID) -> Int {
        self.nextMenuInteractionGeneration &+= 1
        self.menuInteractionGenerations[menuID] = self.nextMenuInteractionGeneration
        return self.nextMenuInteractionGeneration
    }

    mutating func endTrackingSession(_ menuID: MenuID) {
        self.menuInteractionGenerations.removeValue(forKey: menuID)
    }

    /// One-shot viewport restore tied to the menu-tracking session that started a manual refresh.
    @discardableResult
    mutating func armViewportRestore(_ menuID: MenuID) -> Int {
        self.nextViewportRestoreGeneration &+= 1
        self.pendingViewportRestores[menuID] = self.nextViewportRestoreGeneration
        return self.nextViewportRestoreGeneration
    }

    func isCurrentViewportRestore(_ generation: Int, for menuID: MenuID) -> Bool {
        self.pendingViewportRestores[menuID] == generation
    }

    @discardableResult
    mutating func consumeViewportRestore(_ menuID: MenuID, generation: Int) -> Bool {
        guard self.isCurrentViewportRestore(generation, for: menuID) else { return false }
        self.pendingViewportRestores.removeValue(forKey: menuID)
        return true
    }

    mutating func cancelViewportRestore(_ menuID: MenuID) {
        self.pendingViewportRestores.removeValue(forKey: menuID)
    }

    mutating func removeMenu(_ menuID: MenuID) {
        self.renderedVersions.removeValue(forKey: menuID)
        self.deferredUntilNextOpen.remove(menuID)
        self.parentRebuildsDeferredDuringTracking.remove(menuID)
        self.endTrackingSession(menuID)
        self.cancelViewportRestore(menuID)
    }

    mutating func clearMenuTracking() {
        self.renderedVersions.removeAll(keepingCapacity: false)
        self.deferredUntilNextOpen.removeAll(keepingCapacity: false)
        self.parentRebuildsDeferredDuringTracking.removeAll(keepingCapacity: false)
        self.menuInteractionGenerations.removeAll(keepingCapacity: false)
        self.pendingViewportRestores.removeAll(keepingCapacity: false)
    }

    #if DEBUG
    mutating func replaceContentVersionForTesting(_ version: Int) {
        self.contentVersion = version
    }

    mutating func replaceRenderedVersionsForTesting(_ versions: [MenuID: Int]) {
        self.renderedVersions = versions
    }

    mutating func replaceDeferredMenusForTesting(_ menuIDs: Set<MenuID>) {
        self.deferredUntilNextOpen = menuIDs
    }
    #endif
}

struct MenuRebuildRequestRegistry<MenuID: Hashable> {
    private var nextToken = 0
    private(set) var tokens: [MenuID: Int] = [:]

    mutating func replaceRequest(for menuID: MenuID) -> Int {
        self.nextToken &+= 1
        self.tokens[menuID] = self.nextToken
        return self.nextToken
    }

    func isCurrent(_ token: Int, for menuID: MenuID) -> Bool {
        self.tokens[menuID] == token
    }

    @discardableResult
    mutating func finish(_ token: Int, for menuID: MenuID) -> Bool {
        guard self.isCurrent(token, for: menuID) else { return false }
        self.tokens.removeValue(forKey: menuID)
        return true
    }

    mutating func cancel(for menuID: MenuID) {
        self.tokens.removeValue(forKey: menuID)
    }

    mutating func cancelAll() {
        self.tokens.removeAll(keepingCapacity: false)
    }
}
