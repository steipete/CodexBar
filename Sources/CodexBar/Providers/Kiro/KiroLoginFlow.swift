import CodexBarCore

@MainActor
extension StatusItemController {
    func runKiroLoginFlow() async {
        self.loginPhase = .requesting
        defer { self.loginPhase = .idle }

        let result = await KiroLoginRunner.run(timeout: 120)
        guard !Task.isCancelled else { return }
        if let info = KiroLoginAlertPresentation.alertInfo(for: result) {
            self.presentLoginAlert(title: info.title, message: info.message)
        }
        let length = result.output.count
        self.loginLogger.info("Kiro login", metadata: ["outcome": "\(result.outcome)", "length": "\(length)"])
        if case .success = result.outcome {
            self.postLoginNotification(for: .kiro)
        }
    }
}
