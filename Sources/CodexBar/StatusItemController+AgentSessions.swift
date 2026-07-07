import AppKit

extension StatusItemController {
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
