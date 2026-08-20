import AppKit
import CodexBarCore
import Foundation
import SwiftUI

private struct AgentSessionMenuRowView: View {
    let title: String
    let width: CGFloat

    var body: some View {
        Text(self.title)
            .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .frame(width: self.width, alignment: .leading)
    }
}

private enum AgentSessionMenuItemIdentifier {
    private static let prefix = "agentSessionAction:"
    private static let separator = "\u{1f}"

    static func make(sessionID: String, remoteHost: String?) -> NSUserInterfaceItemIdentifier {
        let values = "\(remoteHost ?? "")\(self.separator)\(sessionID)"
        let encoded = Data(values.utf8).base64EncodedString()
        return NSUserInterfaceItemIdentifier(self.prefix + encoded)
    }

    static func actionValues(from identifier: NSUserInterfaceItemIdentifier?) -> (String, String?)? {
        guard let rawValue = identifier?.rawValue,
              rawValue.hasPrefix(self.prefix)
        else { return nil }
        let encoded = rawValue.dropFirst(self.prefix.count)
        guard let data = Data(base64Encoded: String(encoded)),
              let values = String(data: data, encoding: .utf8)
        else { return nil }
        let parts = values.split(separator: Character(self.separator), maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        let remoteHost = parts[0].isEmpty ? nil : String(parts[0])
        return (String(parts[1]), remoteHost)
    }
}

extension StatusItemController {
    func wireAgentSessionUpdates() {
        // `onUpdate` only fires when the session content actually changed (the store dedupes
        // no-op rescans); an unconditional per-scan invalidation was half of the #2652 loop.
        self.agentSessions.onUpdate = { [weak self] in
            guard let self else { return }
            if let latestActivityAt = self.agentSessions.latestLocalActivityAt {
                self.store.noteCodingActivityObserved(at: latestActivityAt)
            } else {
                self.store.clearCodingActivityObservation()
            }
            if self.settings.agentSessionsEnabled {
                // Match the store-observation path (`handleObservedStoreMenuChange`): mark menus
                // stale but never rebuild a tracked parent in place. Rebuilding the Overview
                // parent mid-hover replaces the hovered row and force-closes its hosted chart
                // submenu, which is the other half of the #2652 flicker loop.
                self.invalidateMenus(
                    refreshOpenMenus: true,
                    deferOpenParentMenuRebuild: true,
                    allowStaleContentDuringDataRefresh: true)
            }
        }
    }

    func synchronizeAgentSessionsForSettingsChange() {
        let remoteConfigurationChanged =
            self.settings.agentSessionsEnabled != self.lastAgentSessionsEnabled ||
            self.settings.agentSessionsManualHosts != self.lastAgentSessionsManualHosts
        let monitoringChanged =
            self.settings.refreshFrequency != self.lastAgentSessionsRefreshFrequency ||
            self.settings.adaptiveActivityScanningEnabled != self.lastAdaptiveActivityScanningEnabled
        guard remoteConfigurationChanged || monitoringChanged else { return }

        self.lastAgentSessionsEnabled = self.settings.agentSessionsEnabled
        self.lastAgentSessionsManualHosts = self.settings.agentSessionsManualHosts
        self.lastAgentSessionsRefreshFrequency = self.settings.refreshFrequency
        self.lastAdaptiveActivityScanningEnabled = self.settings.adaptiveActivityScanningEnabled
        if !self.settings.adaptiveActivityScanningEnabled {
            self.store.clearCodingActivityObservation()
        }
        self.agentSessions.settingsDidChange(remoteConfigurationChanged: remoteConfigurationChanged)
    }

    @objc func focusAgentSession(_ sender: NSMenuItem) {
        if let values = sender.representedObject as? [String], let sessionID = values.first {
            let remoteHost = values.count > 1 && !values[1].isEmpty ? values[1] : nil
            self.focusAgentSession(id: sessionID, remoteHost: remoteHost)
            return
        }
        guard let (sessionID, remoteHost) = AgentSessionMenuItemIdentifier.actionValues(from: sender.identifier)
        else { return }
        self.focusAgentSession(id: sessionID, remoteHost: remoteHost)
    }

    func makeAgentSessionMenuItem(
        title: String,
        session: AgentSession,
        remoteHost: String?,
        width: CGFloat) -> NSMenuItem
    {
        let action = MenuDescriptor.MenuAction.focusAgentSession(session, remoteHost: remoteHost)
        let (selector, represented) = self.selector(for: action)
        guard self.menuCardRenderingEnabledForController else {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = represented
            return item
        }

        // Native menu item titles contribute their full natural width to the popup. Put the text
        // in a fixed-width hosted row instead, so it truncates within the width chosen by the rest
        // of the menu rather than expanding the popup for an unusually long project or session name.
        let item = self.makeMenuCardItem(
            AgentSessionMenuRowView(title: title, width: width),
            id: "agentSession:\(remoteHost ?? "local"):\(session.id)",
            width: width,
            heightCacheScope: "agentSession",
            heightCacheFingerprint: "singleLine",
            onClick: { [weak self] in
                self?.focusAgentSession(id: session.id, remoteHost: remoteHost)
            })
        item.toolTip = title
        // The hosted row handles pointer input. Preserve AppKit's keyboard activation path too.
        item.target = self
        item.action = selector
        // Keep the card identifier in `representedObject` for view recycling and height caching.
        // The native action gets its payload from the private identifier instead.
        item.identifier = AgentSessionMenuItemIdentifier.make(sessionID: session.id, remoteHost: remoteHost)
        return item
    }

    private func focusAgentSession(id: String, remoteHost: String?) {
        let session = if let remoteHost {
            self.agentSessions.remoteHosts
                .first(where: { $0.host == remoteHost })?
                .sessions.first(where: { $0.id == id })
        } else {
            self.agentSessions.localSessions.first(where: { $0.id == id })
        }
        guard let session else { return }
        self.agentSessions.focus(session, remoteHost: remoteHost)
    }
}
