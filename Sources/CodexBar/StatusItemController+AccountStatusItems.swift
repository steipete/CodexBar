import AppKit
import CodexBarCore
import CryptoKit
import SwiftUI

extension StatusItemController {
    struct AccountStatusItemKey: Hashable {
        let provider: UsageProvider
        let accountID: String
    }

    enum AccountStatusItemContext {
        case token(provider: UsageProvider, account: ProviderTokenAccount)
        case codex(account: CodexVisibleAccount)

        var provider: UsageProvider {
            switch self {
            case let .token(provider, _): provider
            case .codex: .codex
            }
        }

        var displayName: String {
            switch self {
            case let .token(_, account): account.displayName
            case let .codex(account): account.displayName
            }
        }

        var accountInfo: AccountInfo {
            switch self {
            case let .token(_, account): AccountInfo(email: account.displayName, plan: nil)
            case let .codex(account): AccountInfo(email: account.email, plan: account.workspaceLabel)
            }
        }
    }

    func isActiveAccountContext(_ context: AccountStatusItemContext) -> Bool {
        switch context {
        case let .token(provider, account):
            self.settings.selectedTokenAccount(for: provider)?.id == account.id
        case let .codex(account):
            self.settings.codexVisibleAccountProjection.activeVisibleAccountID == account.id
        }
    }

    private func accountStatusItemDisplayName(
        for key: AccountStatusItemKey,
        context: AccountStatusItemContext) -> String
    {
        let providerName = self.store.metadata(for: key.provider).displayName
        let accountName = PersonalInfoRedactor
            .redactEmails(in: context.displayName, isEnabled: self.settings.hidePersonalInfo)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let accountName, !accountName.isEmpty else { return providerName }
        return "\(providerName) — \(accountName)"
    }

    func lazyAccountStatusItem(
        for key: AccountStatusItemKey,
        context: AccountStatusItemContext) -> NSStatusItem
    {
        let displayName = self.accountStatusItemDisplayName(for: key, context: context)
        if let existing = self.accountStatusItems[key] {
            self.accountStatusItemContexts[key] = context
            let title = "\(Self.statusItemAccessibilityTitle) — \(displayName)"
            existing.button?.setAccessibilityTitle(title)
            existing.button?.toolTip = title
            return existing
        }
        let item = Self.makeStatusItem(
            statusBar: self.statusBar,
            identity: .account(key),
            defaults: self.settings.userDefaults,
            legacyDefaultItemIndex: nil,
            displayName: displayName)
        self.accountStatusItems[key] = item
        self.accountStatusItemContexts[key] = context
        return item
    }

    static func accountStatusItemKey(provider: UsageProvider, account: ProviderTokenAccount) -> AccountStatusItemKey {
        AccountStatusItemKey(provider: provider, accountID: account.id.uuidString.lowercased())
    }

    static func accountStatusItemKey(account: CodexVisibleAccount) -> AccountStatusItemKey {
        let stableInput = if let storedAccountID = account.storedAccountID {
            storedAccountID.uuidString.lowercased()
        } else {
            "\(String(describing: account.selectionSource))|\(account.id)"
        }
        let opaqueID = account.storedAccountID == nil ? self.stableOpaqueAccountID(stableInput) : stableInput
        return AccountStatusItemKey(provider: .codex, accountID: opaqueID)
    }

    private nonisolated static func stableOpaqueAccountID(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func separateAccountContexts(for provider: UsageProvider) -> [AccountStatusItemKey: AccountStatusItemContext] {
        guard self.settings.accountMenuBarDisplayMode(for: provider) == .separate else { return [:] }
        if provider == .codex {
            let accounts = self.settings.codexVisibleAccountProjection.visibleAccounts
            guard accounts.count > 1 else { return [:] }
            return Dictionary(uniqueKeysWithValues: accounts.map {
                (Self.accountStatusItemKey(account: $0), .codex(account: $0))
            })
        }
        let accounts = self.settings.tokenAccounts(for: provider)
        guard accounts.count > 1 else { return [:] }
        return Dictionary(uniqueKeysWithValues: accounts.map {
            (Self.accountStatusItemKey(provider: provider, account: $0), .token(provider: provider, account: $0))
        })
    }

    func removeAccountStatusItem(for key: AccountStatusItemKey) {
        if let menu = self.accountMenus.removeValue(forKey: key) {
            self.clearPersistentMenuTracking(menu)
        }
        self.accountStatusItemContexts.removeValue(forKey: key)
        guard let item = self.accountStatusItems.removeValue(forKey: key) else { return }
        item.menu = nil
        self.lastAppliedAccountIconRenderSignatures.removeValue(forKey: key)
        self.statusBar.removeStatusItem(item)
    }

    func populateAccountMenuIfNeeded(_ menu: NSMenu) -> Bool {
        guard let key = self.menuAccountStatusItemKeys[ObjectIdentifier(menu)],
              let context = self.accountStatusItemContexts[key]
        else { return false }
        self.populateAccountMenu(menu, key: key, context: context)
        return true
    }

    private func populateAccountMenu(
        _ menu: NSMenu,
        key: AccountStatusItemKey,
        context: AccountStatusItemContext)
    {
        let accountSnapshot: (snapshot: UsageSnapshot?, error: String?)? = switch context {
        case let .token(provider, account):
            self.store.accountSnapshots[provider.instanceID]?
                .first(where: { $0.account.id == account.id })
                .map { ($0.snapshot, $0.error) }
        case let .codex(account):
            self.store.codexAccountSnapshots
                .first(where: { $0.id == account.id })
                .map { ($0.snapshot, $0.error) }
        }
        let provider = context.provider
        let includesProviderAdjuncts = self.isActiveAccountContext(context)
        let descriptor = MenuDescriptor.build(
            provider: provider,
            store: self.store,
            settings: self.settings,
            account: context.accountInfo,
            managedCodexAccountCoordinator: self.managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator,
            updateReady: self.updater.updateStatus.isUpdateReady)
        let actions = self.accountScopedSections(descriptor.sections)
        let menuWidth = self.menuCardWidth(
            for: [provider],
            selectedProvider: provider,
            descriptor: descriptor)

        self.performMenuMutationWithoutAnimation {
            menu.removeAllItems()
            if let model = self.menuCardModel(
                for: provider,
                snapshotOverride: accountSnapshot?.snapshot,
                errorOverride: accountSnapshot?.error,
                forceOverrideCard: true,
                accountOverride: context.accountInfo,
                allowsProviderDataForAccountOverride: includesProviderAdjuncts)
            {
                self.addAccountMenuCard(
                    AccountMenuCardInput(
                        model: model,
                        provider: provider,
                        key: key,
                        width: menuWidth,
                        includesProviderAdjuncts: includesProviderAdjuncts),
                    to: menu)
            }
            self.addActionableSections(actions, to: menu, width: menuWidth)
        }
    }

    private struct AccountMenuCardInput {
        let model: UsageMenuCardView.Model
        let provider: UsageProvider
        let key: AccountStatusItemKey
        let width: CGFloat
        let includesProviderAdjuncts: Bool
    }

    private func addAccountMenuCard(_ input: AccountMenuCardInput, to menu: NSMenu) {
        let model = input.model
        let provider = input.provider
        let key = input.key
        let width = input.width
        let includesProviderAdjuncts = input.includesProviderAdjuncts
        let openAIContext = includesProviderAdjuncts
            ? self.openAIWebContext(currentProvider: provider, showAllAccounts: false)
            : OpenAIWebContext(
                hasUsageBreakdown: false,
                hasCreditsHistory: false,
                hasCostHistory: false,
                canShowBuyCredits: false,
                hasOpenAIWebMenuItems: false)
        let menuContext = MenuCardContext(
            currentProvider: provider,
            selectedProvider: provider,
            menuWidth: width,
            codexAccountDisplay: nil,
            tokenAccountDisplay: nil,
            openAIContext: openAIContext)
        if includesProviderAdjuncts,
           openAIContext.hasOpenAIWebMenuItems || self.requiresSectionedMenuForProviderDerivedCost(provider: provider)
        {
            let webItems = OpenAIWebMenuItems(
                hasUsageBreakdown: openAIContext.hasUsageBreakdown,
                hasCreditsHistory: openAIContext.hasCreditsHistory,
                hasCostHistory: openAIContext.hasCostHistory,
                canShowBuyCredits: openAIContext.canShowBuyCredits)
            self.addMenuCardSections(to: menu, model: model, layoutModel: model, width: width, webItems: webItems)
            self.addOpenAIWebItemsIfNeeded(
                to: menu,
                currentProvider: provider,
                context: openAIContext,
                addedOpenAIWebItems: true)
        } else {
            menu.addItem(self.makeMenuCardItem(
                UsageMenuCardView(model: model, width: width),
                id: "accountMenuCard",
                width: width,
                heightCacheScope: "\(provider.rawValue)-account-\(key.accountID)",
                containsInteractiveControls: true))
            if includesProviderAdjuncts {
                _ = self.addStorageMenuCardSection(to: menu, provider: provider, width: width)
            }
        }
        if includesProviderAdjuncts {
            self.addUsageHistoryClusterIfNeeded(to: menu, context: menuContext)
        }
        if menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
    }

    private func accountScopedSections(
        _ sections: [MenuDescriptor.Section]) -> [MenuDescriptor.Section]
    {
        sections.map { section in
            MenuDescriptor.Section(entries: section.entries.compactMap(self.accountScopedEntry))
        }
    }

    private func accountScopedEntry(_ entry: MenuDescriptor.Entry) -> MenuDescriptor.Entry? {
        switch entry {
        case let .action(_, action) where !Self.isAccountScopedActionSafe(action):
            return nil
        case let .submenu(title, image, items):
            guard !items.contains(where: { item in
                item.action.map { !Self.isAccountScopedActionSafe($0) } ?? false
            }) else { return nil }
            return .submenu(title, image, items)
        default:
            return entry
        }
    }

    private static func isAccountScopedActionSafe(_ action: MenuDescriptor.MenuAction) -> Bool {
        switch action {
        case .addCodexAccount, .requestCodexSystemPromotion, .addProviderAccount, .switchAccount:
            false
        default:
            true
        }
    }
}
