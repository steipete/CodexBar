import AppKit
import CodexBarCore
import CryptoKit

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

    func lazyAccountStatusItem(
        for key: AccountStatusItemKey,
        context: AccountStatusItemContext) -> NSStatusItem
    {
        if let existing = self.accountStatusItems[key] {
            self.accountStatusItemContexts[key] = context
            let title = "\(Self.statusItemAccessibilityTitle) — " +
                "\(self.store.metadata(for: key.provider).displayName) — \(context.displayName)"
            existing.button?.setAccessibilityTitle(title)
            existing.button?.toolTip = title
            return existing
        }
        let item = Self.makeStatusItem(
            statusBar: self.statusBar,
            identity: .account(key),
            defaults: self.settings.userDefaults,
            legacyDefaultItemIndex: nil,
            displayName: "\(self.store.metadata(for: key.provider).displayName) — \(context.displayName)")
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
}
