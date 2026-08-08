import CodexBarCore

@MainActor
extension StatusItemController {
    @discardableResult
    func runKiroLoginFlow() async -> Bool {
        self.loginPhase = .requesting
        defer { self.loginPhase = .idle }

        let result = await KiroLoginRunner.run(timeout: 120) { [weak self] progressOutput in
            Task { @MainActor in
                self?.presentLoginAlert(
                    title: L("Complete Kiro login in your browser"),
                    message: progressOutput)
            }
        }
        guard !Task.isCancelled else { return false }
        if let info = KiroLoginAlertPresentation.alertInfo(for: result) {
            self.presentLoginAlert(title: info.title, message: info.message)
        }
        let length = result.output.count
        self.loginLogger.info("Kiro login", metadata: ["outcome": "\(result.outcome)", "length": "\(length)"])
        guard case .success = result.outcome else { return false }
        self.postLoginNotification(for: .kiro)
        return true
    }
}
