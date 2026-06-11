import CodexBarCore
import Foundation

@MainActor
extension StatusItemController {
    func runPoeLoginFlow() async {
        let store = self.store
        let phaseHandler: @Sendable (PoeLoginRunner.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in
                switch phase {
                case .waitingBrowser:
                    self?.loginPhase = .waitingBrowser
                }
            }
        }

        let result = await PoeLoginRunner.run(onPhaseChange: phaseHandler) { [weak self] token in
            Task { @MainActor in
                guard let self else { return }
                self.settings.updateProviderConfig(provider: .poe) { entry in
                    entry.secretKey = token.apiKey
                    if let expiresIn = token.expiresInSeconds {
                        entry.workspaceID = String(Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970)
                    } else {
                        entry.workspaceID = nil
                    }
                }
                await store.refresh()
                CodexBarLog.logger(LogCategories.login).info("Auto-refreshed after Poe OAuth")
            }
        }

        guard !Task.isCancelled else { return }
        self.loginPhase = .idle
        self.presentPoeLoginResult(result)
        self.loginLogger.info("Poe login", metadata: ["outcome": self.describe(result.outcome)])
        if case .success = result.outcome {
            self.postLoginNotification(for: .poe)
        }
    }
}
