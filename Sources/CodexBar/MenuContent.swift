import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct MenuContent: View {
    @Bindable var store: UsageStore
    @Bindable var settings: SettingsStore
    let account: AccountInfo
    let updater: UpdaterProviding
    let provider: UsageProvider?
    let actions: MenuActions

    var body: some View {
        let descriptor = MenuDescriptor.build(
            provider: self.provider,
            store: self.store,
            settings: self.settings,
            account: self.account,
            updateReady: self.updater.updateStatus.isUpdateReady)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(descriptor.sections.enumerated()), id: \.offset) { index, section in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                        self.row(for: entry)
                    }
                }
                if index < descriptor.sections.count - 1 {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 260, alignment: .leading)
    }

    @ViewBuilder
    private func row(for entry: MenuDescriptor.Entry) -> some View {
        switch entry {
        case let .text(text, style):
            switch style {
            case .headline:
                Text(text).font(.headline)
                    .accessibilityLabel(text)
            case .primary:
                Text(text)
                    .accessibilityLabel(text)
            case .secondary:
                Text(text).foregroundStyle(.secondary).font(.footnote)
                    .accessibilityLabel(text)
            }
        case let .action(title, action):
            Button {
                self.perform(action)
            } label: {
                if let icon = self.iconName(for: action) {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .imageScale(.medium)
                            .frame(width: 18, alignment: .center)
                        Text(title)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(title)
                } else {
                    Text(title)
                        .accessibilityLabel(title)
                }
            }
            .buttonStyle(.plain)
        case let .submenu(title, systemImageName, submenuItems):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let systemImageName {
                        Image(systemName: systemImageName)
                    }
                    Text(title).font(.headline)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(title)
                ForEach(Array(submenuItems.enumerated()), id: \.offset) { _, submenuItem in
                    HStack(spacing: 8) {
                        if submenuItem.isChecked {
                            Image(systemName: "checkmark")
                                .imageScale(.small)
                                .frame(width: 18, alignment: .center)
                        } else {
                            Spacer().frame(width: 18)
                        }
                        Text(submenuItem.title)
                            .foregroundStyle(submenuItem.isEnabled ? .primary : .secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(submenuItem.title)
                }
            }
        case .divider:
            Divider()
        }
    }

    private func iconName(for action: MenuDescriptor.MenuAction) -> String? {
        action.systemImageName
    }

    private func perform(_ action: MenuDescriptor.MenuAction) {
        switch action {
        case .refresh:
            self.actions.refresh()
        case .refreshAugmentSession:
            self.actions.refreshAugmentSession()
        case .installUpdate:
            self.actions.installUpdate()
        case .dashboard:
            self.actions.openDashboard()
        case .statusPage:
            self.actions.openStatusPage()
        case .addCodexAccount:
            self.actions.addCodexAccount()
        case .requestCodexSystemPromotion:
            return
        case let .addProviderAccount(provider):
            self.actions.switchAccount(provider)
        case let .switchAccount(provider):
            self.actions.switchAccount(provider)
        case let .openTerminal(command):
            self.actions.openTerminal(command)
        case let .loginToProvider(url):
            if let urlObj = URL(string: url) {
                NSWorkspace.shared.open(urlObj)
            }
        case .settings:
            self.actions.openSettings()
        case .about:
            self.actions.openAbout()
        case .quit:
            self.actions.quit()
        case let .copyError(message):
            self.actions.copyError(message)
        }
    }
}

struct MenuActions {
    let installUpdate: () -> Void
    let refresh: () -> Void
    let refreshAugmentSession: () -> Void
    let openDashboard: () -> Void
    let openStatusPage: () -> Void
    let addCodexAccount: () -> Void
    let switchAccount: (UsageProvider) -> Void
    let openTerminal: (String) -> Void
    let openSettings: () -> Void
    let openAbout: () -> Void
    let quit: () -> Void
    let copyError: (String) -> Void
}

@MainActor
struct StatusIconView: View {
    @Bindable var store: UsageStore
    let provider: UsageProvider

    var body: some View {
        Image(nsImage: self.icon)
            .renderingMode(.template)
            .interpolation(.none)
            .accessibilityLabel(self.accessibilityLabel)
            .accessibilityValue(self.accessibilityValue)
    }

    private var accessibilityLabel: String {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: self.provider)
        return descriptor.metadata.displayName
    }

    private var accessibilityValue: String {
        let snapshot = self.store.snapshot(for: self.provider)
        guard let snap = snapshot else {
            return "No data"
        }
        let remaining = IconRemainingResolver.resolvedRemaining(
            snapshot: snap,
            style: self.store.style(for: self.provider))
        let primary = remaining.primary
        let percent = primary.map { "\(Int($0 * 100)) percent remaining" } ?? "Unknown"
        let stale = self.store.isStale(provider: self.provider)
        return stale ? "\(percent), stale data" : percent
    }

    private var icon: NSImage {
        let snapshot = self.store.snapshot(for: self.provider)
        let remaining = snapshot.map {
            IconRemainingResolver.resolvedRemaining(snapshot: $0, style: self.store.style(for: self.provider))
        }
        let creditsProjection = self.store.codexConsumerProjectionIfNeeded(
            for: self.provider,
            surface: .menuBar,
            snapshotOverride: snapshot,
            now: snapshot?.updatedAt ?? Date())
        let creditsRemaining = creditsProjection?.menuBarFallback == .creditsBalance
            ? self.store.codexMenuBarCreditsRemaining(
                snapshotOverride: snapshot,
                now: snapshot?.updatedAt ?? Date())
            : nil
        return IconRenderer.makeIcon(
            primaryRemaining: remaining?.primary,
            weeklyRemaining: remaining?.secondary,
            creditsRemaining: creditsRemaining,
            stale: self.store.isStale(provider: self.provider),
            style: self.store.style(for: self.provider),
            statusIndicator: self.store.statusIndicator(for: self.provider))
    }
}
