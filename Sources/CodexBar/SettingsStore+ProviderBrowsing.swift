import CodexBarCore
import Foundation

struct ProviderOrderUndo {
    let id = UUID()
    let before: [ProviderInstanceID]
    let after: [ProviderInstanceID]
    var restoreAlphabetical: Bool?
}

extension SettingsStore {
    var providersEnabledOnly: Bool {
        get { self.defaultsState.providersEnabledOnly }
        set { self.setDefault(\.providersEnabledOnly, newValue, key: "providersEnabledOnly") }
    }

    var canUndoProviderOrderChange: Bool {
        guard let undo = self.providerOrderUndo else { return false }
        return self.configSnapshot.providers.map(\.id) == undo.after
    }

    @discardableResult
    func moveVisibleProviders(
        _ visibleOrder: [ProviderInstanceID],
        fromOffsets: IndexSet,
        toOffset: Int) -> Bool
    {
        guard !self.providersSortedAlphabetically, !self.providersEnabledOnly else { return false }
        let before = self.configSnapshot.providers.map(\.id)
        guard let after = ProviderOrderMutation.moving(
            visibleOrder: visibleOrder, fromOffsets: fromOffsets, toOffset: toOffset, in: before),
            after != before
        else { return false }
        self.setProviderOrder(after)
        self.providerOrderUndo = ProviderOrderUndo(
            before: before, after: self.configSnapshot.providers.map(\.id), restoreAlphabetical: nil)
        return true
    }

    @discardableResult
    func restoreDefaultProviderOrder() -> Bool {
        let before = self.configSnapshot.providers.map(\.id)
        let present = Set(before)
        let defaults = UsageProvider.allCases.map(\.instanceID).filter { present.contains($0) }
        let alphabetical = self.providersSortedAlphabetically
        guard let after = ProviderOrderMutation.merging(visibleOrder: defaults, into: before),
              after != before || alphabetical
        else { return false }
        self.setProviderOrder(after)
        self.providersSortedAlphabetically = false
        self.providerOrderUndo = ProviderOrderUndo(
            before: before, after: self.configSnapshot.providers.map(\.id), restoreAlphabetical: alphabetical)
        return true
    }

    func registerProviderOrderUndo(in manager: UndoManager?) {
        self.providerOrderUndoManager?.removeAllActions(withTarget: self)
        self.providerOrderUndoManager = manager
        guard let manager, let actionID = self.providerOrderUndo?.id else { return }
        manager.removeAllActions(withTarget: self)
        manager.registerUndo(withTarget: self) { settings in
            MainActor.assumeIsolated { settings.undoProviderOrderChange(matching: actionID) }
        }
        manager.setActionName(L("Change provider order"))
    }

    func clearProviderOrderUndo() {
        self.providerOrderUndo = nil
        if let manager = self.providerOrderUndoManager, !manager.isUndoing, !manager.isRedoing {
            manager.removeAllActions(withTarget: self)
        }
        self.providerOrderUndoManager = nil
    }

    @discardableResult
    func undoProviderOrderChange(matching actionID: UUID? = nil) -> Bool {
        guard self.canUndoProviderOrderChange, let undo = self.providerOrderUndo,
              actionID == nil || actionID == undo.id
        else { return false }
        self.clearProviderOrderUndo()
        self.setProviderOrder(undo.before)
        if let alphabetical = undo.restoreAlphabetical { self.providersSortedAlphabetically = alphabetical }
        return true
    }
}

enum ProviderOrderMutation {
    /// Replace only the displayed providers' slots, retaining every hidden provider and its position.
    static func merging(
        visibleOrder: [ProviderInstanceID],
        into fullOrder: [ProviderInstanceID]) -> [ProviderInstanceID]?
    {
        let visible = Set(visibleOrder)
        guard visible.count == visibleOrder.count,
              Set(fullOrder).count == fullOrder.count,
              fullOrder.filter({ visible.contains($0) }).count == visibleOrder.count
        else { return nil }
        var index = 0
        return fullOrder.map { id in
            guard visible.contains(id) else { return id }
            defer { index += 1 }
            return visibleOrder[index]
        }
    }

    static func moving(
        visibleOrder: [ProviderInstanceID],
        fromOffsets: IndexSet,
        toOffset: Int,
        in fullOrder: [ProviderInstanceID]) -> [ProviderInstanceID]?
    {
        let visible = Set(visibleOrder)
        guard !fromOffsets.isEmpty,
              fromOffsets.allSatisfy({ visibleOrder.indices.contains($0) }),
              (0...visibleOrder.count).contains(toOffset),
              fullOrder.filter({ visible.contains($0) }) == visibleOrder
        else { return nil }
        let moved = fromOffsets.map { visibleOrder[$0] }
        var result = visibleOrder.enumerated().filter { !fromOffsets.contains($0.offset) }.map(\.element)
        let destination = toOffset - fromOffsets.count(where: { $0 < toOffset })
        result.insert(contentsOf: moved, at: destination)
        return self.merging(visibleOrder: result, into: fullOrder)
    }
}
