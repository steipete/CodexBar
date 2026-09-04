import AppKit
import CodexBarCore

/// Shared renderer for the compact multi-account menu layout: full cards for the
/// active and explicitly expanded accounts, one-line rows for the rest, and a
/// summary row standing in for the collapsed healthy tail. Used by every
/// multi-account presentation (claude-swap, token accounts, Codex accounts).
extension StatusItemController {
    func compactAccountPlan(
        for provider: UsageProvider,
        accounts: [ProviderAccountUsageSnapshot]) -> AccountMenuLayoutPlanner.Plan
    {
        AccountMenuLayoutPlanner.plan(
            accounts: accounts,
            expandedAccountIDs: self.compactAccountExpandedIDs,
            healthyTailExpanded: self.compactAccountExpandedHealthyTailProviders.contains(provider.instanceID))
    }

    struct CompactAccountMenuRendering {
        let plan: AccountMenuLayoutPlanner.Plan
        let accounts: [ProviderAccountUsageSnapshot]
        let idPrefix: String
        let cardModel: (ProviderAccountUsageSnapshot) -> UsageMenuCardView.Model?
        var planAction: ((ProviderAccountUsageSnapshot) -> (() -> Void)?)?
    }

    /// Renders the token-account list with the compact plan when it applies.
    /// Returns false when the caller should fall back to the stacked cards.
    func addCompactTokenAccountMenuIfPlanned(
        display: TokenAccountMenuDisplay,
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext) -> Bool
    {
        let provider = context.currentProvider
        let projected = Self.projectedTokenAccounts(
            provider: provider,
            snapshots: display.snapshots,
            selectedAccountID: self.settings.effectiveSelectedTokenAccount(for: provider)?.id)
        let plan = self.compactAccountPlan(for: provider, accounts: projected)
        guard plan.usesCompactLayout else { return false }
        let snapshotsByID = Dictionary(
            uniqueKeysWithValues: display.snapshots.map { ($0.account.id.uuidString, $0) })
        self.addCompactAccountMenuRows(
            CompactAccountMenuRendering(
                plan: plan,
                accounts: projected,
                idPrefix: "tokenAccount",
                cardModel: { [weak self] projectedAccount in
                    guard let self,
                          let accountSnapshot = snapshotsByID[projectedAccount.id.opaqueID] else { return nil }
                    return self.tokenAccountMenuCardModel(for: provider, accountSnapshot: accountSnapshot)
                },
                planAction: nil),
            to: menu,
            captureMenu: captureMenu,
            context: context)
        return true
    }

    /// Renders the Codex account list with the compact plan when it applies.
    /// Workspace-grouped lists keep their sectioned stacked layout; the flat
    /// compact plan would lose the grouping headers.
    func addCompactCodexAccountMenuIfPlanned(
        display: CodexAccountMenuDisplay,
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext) -> Bool
    {
        guard !display.showsWorkspaceGroups else { return false }
        let projected = Self.projectedCodexAccounts(
            display: display,
            includeOptionalCredits: self.settings.showOptionalCreditsAndExtraUsage)
        let plan = self.compactAccountPlan(for: .codex, accounts: projected)
        guard plan.usesCompactLayout else { return false }
        let snapshotsByAccountID = Dictionary(
            uniqueKeysWithValues: display.snapshots.map { ($0.account.id, $0) })
        let accountsByID = Dictionary(
            uniqueKeysWithValues: display.accounts.map { ($0.id, $0) })
        self.addCompactAccountMenuRows(
            CompactAccountMenuRendering(
                plan: plan,
                accounts: projected,
                idPrefix: "codexAccount",
                cardModel: { [weak self] projectedAccount in
                    guard let self,
                          let account = accountsByID[projectedAccount.id.opaqueID] else { return nil }
                    let accountSnapshot = snapshotsByAccountID[account.id]
                    let health = CodexAccountHealth.status(for: account, error: accountSnapshot?.error)
                    return self.menuCardModel(
                        for: .codex,
                        snapshotOverride: accountSnapshot?.snapshot,
                        errorOverride: health.label,
                        forceOverrideCard: accountSnapshot == nil,
                        accountOverride: self.accountInfo(for: account),
                        historySelectionOverride: self.store.codexPlanUtilizationHistorySelection(
                            forVisibleAccount: account),
                        creditsOverride: accountSnapshot?.credits)
                },
                planAction: nil),
            to: menu,
            captureMenu: captureMenu,
            context: context)
        return true
    }

    func addCompactAccountMenuRows(
        _ rendering: CompactAccountMenuRendering,
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        let plan = rendering.plan
        let idPrefix = rendering.idPrefix
        let cardModel = rendering.cardModel
        let planAction = rendering.planAction
        let provider = context.currentProvider
        let accountsByID = Dictionary(uniqueKeysWithValues: rendering.accounts.map { ($0.id, $0) })
        let progressColor = UsageMenuCardView.Model.progressColor(for: provider)
        var previousRowWasCard = false
        for (index, row) in plan.rows.enumerated() {
            switch row {
            case let .card(accountID):
                guard let account = accountsByID[accountID],
                      let model = cardModel(account) else { continue }
                if index > 0 {
                    menu.addItem(.separator())
                }
                let collapseClick: (() -> Void)? = account.isActive ? nil : { [weak self, weak captureMenu] in
                    self?.toggleCompactAccountExpansion(accountID, menu: captureMenu)
                }
                menu.addItem(self.makeMenuCardItem(
                    UsageMenuCardView(
                        model: model,
                        width: context.menuWidth,
                        planAction: planAction?(account)),
                    id: "\(idPrefix)Card-\(accountID.opaqueID)",
                    width: context.menuWidth,
                    heightCacheScope: "\(idPrefix)-card-\(accountID.opaqueID)",
                    heightCacheFingerprint: model.heightFingerprint(section: "card"),
                    containsInteractiveControls: true,
                    onClick: collapseClick))
                previousRowWasCard = true
            case let .compact(compactRow):
                if previousRowWasCard {
                    menu.addItem(.separator())
                }
                let rowModel = MenuCardCompactAccountRowView.Model(
                    label: PersonalInfoRedactor.redactEmail(
                        compactRow.label,
                        isEnabled: self.settings.hidePersonalInfo),
                    headroomPercent: compactRow.headroomPercent,
                    severity: compactRow.severity,
                    constraintDetail: compactRow.constraintDetail,
                    hasError: compactRow.hasError,
                    showsBestBadge: compactRow.isBestCandidate)
                let accountID = compactRow.accountID
                menu.addItem(self.makeMenuCardItem(
                    MenuCardCompactAccountRowView(
                        model: rowModel,
                        progressColor: progressColor,
                        width: context.menuWidth),
                    id: "\(idPrefix)Compact-\(accountID.opaqueID)",
                    width: context.menuWidth,
                    heightCacheScope: "\(idPrefix)-compact-\(accountID.opaqueID)",
                    heightCacheFingerprint: rowModel.heightFingerprint,
                    onClick: { [weak self, weak captureMenu] in
                        self?.toggleCompactAccountExpansion(accountID, menu: captureMenu)
                    }))
                previousRowWasCard = false
            case let .collapsedHealthy(count):
                let view = MenuCardCollapsedAccountsRowView(count: count, width: context.menuWidth)
                menu.addItem(self.makeMenuCardItem(
                    view,
                    id: "\(idPrefix)Collapsed",
                    width: context.menuWidth,
                    heightCacheScope: "\(idPrefix)-collapsed",
                    heightCacheFingerprint: "collapsed-\(count)",
                    onClick: { [weak self, weak captureMenu] in
                        self?.expandCompactAccountHealthyTail(for: provider, menu: captureMenu)
                    }))
                previousRowWasCard = false
            }
        }
        if !plan.rows.isEmpty {
            menu.addItem(.separator())
        }
        if self.addStorageMenuCardSection(to: menu, provider: provider, width: context.menuWidth) {
            menu.addItem(.separator())
        }
    }

    /// Classic stacked layout: one full card per account. Shared fallback for
    /// every multi-account list below the compact-layout threshold.
    func addStackedMenuCards(
        _ cards: [UsageMenuCardView.Model],
        to menu: NSMenu,
        context: MenuCardContext,
        planAction: ((Int) -> (() -> Void)?)? = nil)
    {
        if cards.isEmpty, let model = self.menuCardModel(for: context.selectedProvider) {
            let renderedModel = self.menuCardRefreshMonitor.model(for: model.provider, fallback: model)
            menu.addItem(self.makeMenuCardItem(
                UsageMenuCardView(model: model, layoutModel: renderedModel, width: context.menuWidth),
                id: "menuCard",
                width: context.menuWidth,
                heightCacheScope: context.currentProvider.rawValue,
                heightCacheFingerprint: renderedModel.heightFingerprint(section: "card"),
                containsInteractiveControls: true))
            menu.addItem(.separator())
        } else {
            for (index, model) in cards.enumerated() {
                menu.addItem(self.makeMenuCardItem(
                    UsageMenuCardView(
                        model: model,
                        width: context.menuWidth,
                        planAction: planAction?(index)),
                    id: "menuCard-\(index)",
                    width: context.menuWidth,
                    heightCacheScope: "\(context.currentProvider.rawValue)-\(index)",
                    heightCacheFingerprint: model.heightFingerprint(section: "card"),
                    containsInteractiveControls: true))
                if index < cards.count - 1 {
                    menu.addItem(.separator())
                }
            }
            if !cards.isEmpty {
                menu.addItem(.separator())
            }
        }
        if self.addStorageMenuCardSection(to: menu, provider: context.currentProvider, width: context.menuWidth) {
            menu.addItem(.separator())
        }
    }

    // MARK: - Projections

    static func projectedTokenAccounts(
        provider: UsageProvider,
        snapshots: [TokenAccountUsageSnapshot],
        selectedAccountID: UUID?) -> [ProviderAccountUsageSnapshot]
    {
        snapshots.map { accountSnapshot in
            let isActive = accountSnapshot.account.id == selectedAccountID
            return ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(
                    source: "token-account",
                    opaqueID: accountSnapshot.account.id.uuidString),
                provider: provider,
                displayLabel: accountSnapshot.account.displayName,
                isActive: isActive,
                canActivate: !isActive,
                snapshot: accountSnapshot.snapshot,
                error: accountSnapshot.error,
                sourceLabel: accountSnapshot.sourceLabel)
        }
    }

    static func projectedCodexAccounts(
        display: CodexAccountMenuDisplay,
        includeOptionalCredits: Bool = true) -> [ProviderAccountUsageSnapshot]
    {
        let snapshotsByAccountID = Dictionary(uniqueKeysWithValues: display.snapshots.map { ($0.account.id, $0) })
        return display.accounts.map { account in
            let accountSnapshot = snapshotsByAccountID[account.id]
            let health = CodexAccountHealth.status(for: account, error: accountSnapshot?.error)
            let isActive = account.id == display.activeVisibleAccountID || account.isActive
            let credits = includeOptionalCredits ? accountSnapshot?.credits : nil
            return ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(source: "codex-account", opaqueID: account.id),
                provider: .codex,
                displayLabel: account.menuDisplayName,
                isActive: isActive,
                canActivate: !isActive,
                snapshot: Self.snapshotIncludingMonthlyCredit(
                    snapshot: accountSnapshot?.snapshot,
                    credits: credits),
                error: health.label,
                sourceLabel: accountSnapshot?.sourceLabel)
        }
    }

    static func snapshotIncludingMonthlyCredit(
        snapshot: UsageSnapshot?,
        credits: CreditsSnapshot?) -> UsageSnapshot?
    {
        guard let limit = credits?.codexCreditLimit else {
            return snapshot.map { CodexExtraUsageCost.attaching(to: $0, credits: credits) } ?? snapshot
        }
        let monthly = RateWindow(
            usedPercent: limit.usedPercent,
            windowMinutes: nil,
            resetsAt: limit.resetsAt,
            resetDescription: nil)
        guard let snapshot else {
            return CodexExtraUsageCost.attaching(
                to: UsageSnapshot(
                    primary: nil,
                    secondary: nil,
                    tertiary: monthly,
                    updatedAt: limit.updatedAt),
                credits: credits)
        }
        if snapshot.tertiary == nil {
            return CodexExtraUsageCost.attaching(to: snapshot.with(tertiary: monthly), credits: credits)
        }
        let extras = (snapshot.extraRateWindows ?? []) + [
            NamedRateWindow(
                id: "codex-monthly-credit",
                title: limit.title,
                window: monthly),
        ]
        return CodexExtraUsageCost.attaching(to: snapshot.with(extraRateWindows: extras), credits: credits)
    }

    // MARK: - Expansion state

    private func toggleCompactAccountExpansion(_ accountID: ProviderAccountIdentity, menu: NSMenu?) {
        self.advanceMenuInteraction(for: menu)
        if self.compactAccountExpandedIDs.contains(accountID) {
            self.compactAccountExpandedIDs.remove(accountID)
        } else {
            self.compactAccountExpandedIDs.insert(accountID)
        }
        self.invalidateMenus(refreshOpenMenus: true)
    }

    private func expandCompactAccountHealthyTail(for provider: UsageProvider, menu: NSMenu?) {
        self.advanceMenuInteraction(for: menu)
        self.compactAccountExpandedHealthyTailProviders.insert(provider.instanceID)
        self.invalidateMenus(refreshOpenMenus: true)
    }

    /// Compact-layout expansion is per-open transient UI state; reset when the last menu closes.
    func resetCompactAccountMenuExpansionStateIfIdle() {
        guard self.openMenus.isEmpty else { return }
        self.compactAccountExpandedIDs.removeAll()
        self.compactAccountExpandedHealthyTailProviders.removeAll()
    }
}
