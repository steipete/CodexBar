import AppKit
import CodexBarCore

@MainActor
extension StatusItemController {
    func runAntigravityLoginFlow() async -> Bool {
        self.loginPhase = .waitingBrowser

        let port: UInt16 = 19876
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let state = UUID().uuidString

        let clientId = AntigravityOAuthConfig.clientId
        let scopes = [
            "https://www.googleapis.com/auth/cloud-platform",
            "https://www.googleapis.com/auth/userinfo.email",
        ].joined(separator: " ")

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]

        guard let authURL = components.url else {
            self.loginPhase = .idle
            self.presentLoginAlert(title: "Login Error", message: "Failed to build auth URL.")
            return false
        }

        NSWorkspace.shared.open(authURL)

        do {
            let tokens = try await AntigravityOAuthCallbackServer.waitForCallback(
                port: port, expectedState: state, timeout: 120)
            let storage = AntigravityOAuthStorage()
            try storage.saveTokens(tokens)
            AntigravitySessionState.preferRemote = true

            // Force-enable the provider since initial detection may have disabled it
            // (e.g., IDE wasn't running and no tokens existed at startup).
            self.settings.updateProviderConfig(provider: .antigravity) { $0.enabled = true }

            // Clear stale snapshot so menu shows "Refreshing..." instead of old account data.
            self.store.snapshots.removeValue(forKey: .antigravity)
            self.store.errors.removeValue(forKey: .antigravity)
            self.loginPhase = .idle

            let email = tokens.email ?? "your Google account"
            // Show alert on next run loop iteration so return true triggers refresh first.
            DispatchQueue.main.async { [weak self] in
                self?.presentLoginAlert(
                    title: "Antigravity Login Successful",
                    message: "Signed in as \(email). Quota is refreshing now.")
            }
            return true
        } catch {
            self.loginPhase = .idle
            self.presentLoginAlert(
                title: "Antigravity Login Failed",
                message: error.localizedDescription)
            return false
        }
    }
}
