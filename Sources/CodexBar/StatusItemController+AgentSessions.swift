import AppKit

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
        guard let values = sender.representedObject as? [String],
              let sessionID = values.first
        else { return }
        let remoteHost = values.count > 1 && !values[1].isEmpty ? values[1] : nil
        let session = if let remoteHost {
            self.agentSessions.remoteHosts
                .first(where: { $0.host == remoteHost })?
                .sessions.first(where: { $0.id == sessionID })
        } else {
            self.agentSessions.localSessions.first(where: { $0.id == sessionID })
        }
        guard let session else { return }
        self.agentSessions.focus(session, remoteHost: remoteHost)
    }
}
