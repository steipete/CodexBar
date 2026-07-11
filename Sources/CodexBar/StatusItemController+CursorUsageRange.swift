import CodexBarCore

extension StatusItemController {
    func selectCursorUsageRange(_ range: CursorUsageRangeKind) {
        self.settings.cursorUsageRangeKind = range
        self.invalidateMenus(refreshOpenMenus: true)
        self.store.persistWidgetSnapshot(reason: "cursor-range")
    }
}
