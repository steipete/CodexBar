import CodexBarCore
import Foundation

/// Where the selected provider sits in the switcher's rotation, and which providers the previous
/// and next controls move to.
///
/// The switcher used to lay every provider out as a chip in a single row. That never fit: names
/// wrapped mid-word on large tiles, truncated to indistinguishable stems on medium ("Co…" is both
/// Codex and Copilot), and collapsed to a single letter on small, where four of five common
/// providers are a "C". Widgets cannot host a menu or picker, so the control that replaces it pages
/// through providers one at a time — which costs one line instead of a whole row and lets the
/// selected provider always be spelled out in full.
struct ProviderPager: Equatable {
    let selected: UsageProvider
    let previous: UsageProvider
    let next: UsageProvider
    /// 1-based, for the "2/5" position readout.
    let position: Int
    let total: Int

    var isPageable: Bool {
        self.total > 1
    }

    var positionText: String {
        "\(self.position)/\(self.total)"
    }

    /// Wraps around at both ends so either control always leads somewhere.
    static func make(providers: [UsageProvider], selected: UsageProvider) -> ProviderPager? {
        guard !providers.isEmpty else { return nil }
        let index = providers.firstIndex(of: selected) ?? 0
        let resolved = providers[index]
        let count = providers.count
        return ProviderPager(
            selected: resolved,
            previous: providers[(index - 1 + count) % count],
            next: providers[(index + 1) % count],
            position: index + 1,
            total: count)
    }
}

/// Pages display-only companions while the active account remains the tile's headline.
struct WidgetAccountPager {
    let selected: WidgetSnapshot.AccountEntry
    let previous: WidgetSnapshot.AccountEntry
    let next: WidgetSnapshot.AccountEntry
    let position: Int
    let total: Int

    var isPageable: Bool {
        self.total > 1
    }

    var positionText: String {
        "\(self.position)/\(self.total)"
    }

    static func make(
        accounts: [WidgetSnapshot.AccountEntry],
        selectedID: String?,
        excludingAccountID: String?) -> WidgetAccountPager?
    {
        let inactive = accounts.filter { !$0.isActive && $0.id != excludingAccountID }
        guard !inactive.isEmpty else { return nil }
        let index = inactive.firstIndex { $0.id == selectedID } ?? 0
        let count = inactive.count
        return WidgetAccountPager(
            selected: inactive[index],
            previous: inactive[(index - 1 + count) % count],
            next: inactive[(index + 1) % count],
            position: index + 1,
            total: count)
    }

    static func canSelect(accountID: String, provider: UsageProvider, snapshot: WidgetSnapshot) -> Bool {
        guard let account = snapshot.account(id: accountID, provider: provider.instanceID) else { return false }
        return !account.isActive
    }
}
