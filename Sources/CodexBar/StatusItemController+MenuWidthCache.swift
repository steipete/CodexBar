import AppKit
import CodexBarCore

extension StatusItemController {
    private static let measuredStandardMenuWidthCacheLimit = 96

    func menuCardWidth(
        for providers: [UsageProvider],
        selectedProvider: UsageProvider?,
        descriptor: MenuDescriptor) -> CGFloat
    {
        let sectionSets: [(provider: UsageProvider?, sections: [MenuDescriptor.Section])] = if self.shouldMergeIcons,
                                                                                               providers.count > 1
        {
            providers.map { provider in
                if provider == selectedProvider {
                    return (provider, descriptor.sections)
                }
                return (provider, self.makeMenuDescriptor(
                    provider: provider,
                    includeContextualActions: true).sections)
            }
        } else {
            [(selectedProvider, descriptor.sections)]
        }
        return self.measuredMenuCardWidth(for: sectionSets)
    }

    func measuredMenuCardWidth(
        for sectionSets: [(provider: UsageProvider?, sections: [MenuDescriptor.Section])]) -> CGFloat
    {
        let baselineWidth = Self.menuCardBaseWidth
        return sectionSets.reduce(baselineWidth) { width, entry in
            max(width, self.measuredStandardMenuWidth(
                for: entry.sections, baseWidth: baselineWidth, provider: entry.provider))
        }
    }

    func makeMenuDescriptor(
        provider: UsageProvider?,
        includeContextualActions: Bool,
        codexWorkspacesMenuEnabled: Bool = CodexWorkspacesMenuAvailability.isEnabledForCurrentProcess) -> MenuDescriptor
    {
        MenuDescriptor.build(
            provider: provider,
            store: self.store,
            settings: self.settings,
            account: self.account,
            managedCodexAccountCoordinator: self.managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator,
            updateReady: self.updater.updateStatus.isUpdateReady,
            includeContextualActions: includeContextualActions,
            codexWorkspacesMenuEnabled: codexWorkspacesMenuEnabled,
            agentSessionsEnabled: self.settings.agentSessionsEnabled,
            agentSessionLabelStyle: self.settings.agentSessionLabelStyle,
            localAgentSessions: self.agentSessions.localSessions,
            remoteAgentHosts: self.agentSessions.remoteHosts)
    }

    func measuredStandardMenuWidth(
        for sections: [MenuDescriptor.Section],
        baseWidth: CGFloat,
        provider: UsageProvider? = nil) -> CGFloat
    {
        let cacheKey = self.measuredStandardMenuWidthCacheKey(
            for: sections, baseWidth: baseWidth, provider: provider)
        if let cached = self.measuredStandardMenuWidthCache[cacheKey] {
            return cached
        }

        let measuringMenu = NSMenu()
        measuringMenu.autoenablesItems = false
        self.addActionableSections(sections, to: measuringMenu, width: baseWidth, provider: provider)
        let measured = ceil(measuringMenu.size.width)
        if self.measuredStandardMenuWidthCache.count >= Self.measuredStandardMenuWidthCacheLimit {
            self.measuredStandardMenuWidthCache.removeAll(keepingCapacity: true)
        }
        self.measuredStandardMenuWidthCache[cacheKey] = measured
        return measured
    }

    private func measuredStandardMenuWidthCacheKey(
        for sections: [MenuDescriptor.Section],
        baseWidth: CGFloat,
        provider: UsageProvider?) -> String
    {
        var parts = [
            "base=\(Int((baseWidth * 100).rounded()))",
            "status=\(self.store.statusChecksEnabled):\(provider?.rawValue ?? "none")",
            "font=\(Self.menuCardHeightTextScaleToken())",
            self.menuLocalizationSignature(),
        ]
        for section in sections {
            parts.append("[")
            for entry in section.entries {
                parts.append(self.measuredStandardMenuWidthCacheToken(for: entry))
            }
            parts.append("]")
        }
        return parts.joined(separator: "\u{1f}")
    }

    private func measuredStandardMenuWidthCacheToken(for entry: MenuDescriptor.Entry) -> String {
        switch entry {
        case let .text(text, style):
            "text:\(style):\(text)"
        case let .action(_, .focusAgentSession(session, remoteHost)):
            // Session rows are fixed-width hosted views. Their title can change every scan without
            // affecting popup width, so avoid both measurement work and cache churn from its text.
            "focusAgentSession:\(remoteHost ?? "local"):\(session.id)"
        case let .action(title, action):
            "action:\(title):\(self.measuredStandardMenuWidthCacheToken(for: action))"
        case let .unavailable(title, tooltip):
            "unavailable:\(title):\(tooltip ?? "")"
        case let .submenu(title, systemImageName, submenuItems):
            "submenu:\(title):\(systemImageName ?? ""):" + submenuItems.map { item in
                [
                    item.title,
                    item.isEnabled ? "1" : "0",
                    item.isChecked ? "1" : "0",
                    item.action.map(self.measuredStandardMenuWidthCacheToken(for:)) ?? "",
                ].joined(separator: ":")
            }.joined(separator: ",")
        case .divider:
            "divider"
        }
    }

    private func measuredStandardMenuWidthCacheToken(for action: MenuDescriptor.MenuAction) -> String {
        switch action {
        case .installUpdate:
            "installUpdate"
        case .refresh:
            "refresh"
        case .refreshAugmentSession:
            "refreshAugmentSession"
        case .dashboard:
            "dashboard"
        case .statusPage:
            "statusPage"
        case .changelog:
            "changelog"
        case .addCodexAccount:
            "addCodexAccount:\(self.codexAddAccountSubtitle() ?? "")"
        case let .requestCodexSystemPromotion(id):
            "requestCodexSystemPromotion:\(id)"
        case let .addProviderAccount(provider):
            "addProviderAccount:\(provider.rawValue)"
        case let .switchAccount(provider):
            "switchAccount:\(provider.rawValue):\(self.switchAccountSubtitle(for: provider) ?? "")"
        case let .openTerminal(command):
            "openTerminal:\(command)"
        case let .loginToProvider(url):
            "loginToProvider:\(url)"
        case .openCodexWorkspaces:
            CodexWorkspacesWindowIdentity.menuItem
        case .settings:
            "settings"
        case let .providerSettings(provider):
            "providerSettings:\(provider.rawValue)"
        case .about:
            "about"
        case .quit:
            "quit"
        case let .copyError(message):
            "copyError:\(message)"
        case let .focusAgentSession(session, remoteHost):
            "focusAgentSession:\(remoteHost ?? "local"):\(session.id)"
        }
    }
}
