import CodexBarCore
import Foundation

/// Menu-local progress of System account switches, one phase per provider. Pure: callers decide when to rebuild
/// menus or post notifications. The controller reapplies current privacy settings before displaying retained labels.
struct SystemAccountSwitchFeedback: Equatable {
    enum Phase: Equatable {
        case switching(accountID: String, label: String, cliName: String)
        case succeeded(accountID: String, label: String, cliName: String)
        case failed(accountID: String, label: String, title: String, message: String)

        var accountID: String {
            switch self {
            case let .switching(accountID, _, _), let .succeeded(accountID, _, _), let .failed(accountID, _, _, _):
                accountID
            }
        }
    }

    struct Subtitle: Equatable {
        let text: String
        let style: UsageMenuCardView.Model.SubtitleStyle
    }

    struct Notice: Equatable {
        let title: String
        let body: String
    }

    private var phases: [UsageProvider: Phase] = [:]

    func phase(for provider: UsageProvider) -> Phase? {
        self.phases[provider]
    }

    func isSwitching(_ provider: UsageProvider) -> Bool {
        if case .switching = self.phases[provider] { return true }
        return false
    }

    func replacingLabel(_ label: String, for provider: UsageProvider) -> Self {
        var feedback = self
        switch self.phases[provider] {
        case let .switching(accountID, _, cliName):
            feedback.phases[provider] = .switching(accountID: accountID, label: label, cliName: cliName)
        case let .succeeded(accountID, _, cliName):
            feedback.phases[provider] = .succeeded(accountID: accountID, label: label, cliName: cliName)
        case let .failed(accountID, _, title, message):
            feedback.phases[provider] = .failed(accountID: accountID, label: label, title: title, message: message)
        case nil:
            break
        }
        return feedback
    }

    mutating func begin(provider: UsageProvider, accountID: String, label: String, cliName: String) {
        self.phases[provider] = .switching(accountID: accountID, label: label, cliName: cliName)
    }

    mutating func finish(provider: UsageProvider, outcome: SystemAccountSwitchOutcome) {
        guard case let .switching(accountID, label, cliName) = self.phases[provider] else { return }
        switch outcome {
        case .succeeded:
            self.phases[provider] = .succeeded(accountID: accountID, label: label, cliName: cliName)
        case let .failed(title, message):
            self.phases[provider] = .failed(accountID: accountID, label: label, title: title, message: message)
        case .discarded:
            self.phases[provider] = nil
        }
    }

    /// Successes are acknowledged once a menu has closed; failures stay until the next switch.
    mutating func menuDidClose() {
        self.phases = self.phases.filter { _, phase in
            if case .succeeded = phase { return false }
            return true
        }
    }

    /// `accountID` nil means the provider renders a single card, which shows that provider's switch progress.
    func subtitle(for provider: UsageProvider, accountID: String?) -> Subtitle? {
        guard let phase = self.phases[provider] else { return nil }
        if let accountID, phase.accountID != accountID { return nil }
        switch phase {
        case let .switching(_, label, cliName):
            return Subtitle(text: String(format: L("Switching %1$@ to %2$@…"), cliName, label), style: .loading)
        case let .succeeded(_, label, _):
            return Subtitle(text: String(format: L("%@ is now the System account"), label), style: .info)
        case let .failed(_, _, _, message):
            return Subtitle(text: message, style: .error)
        }
    }

    func notification(for provider: UsageProvider) -> Notice? {
        switch self.phases[provider] {
        case let .succeeded(_, label, cliName):
            Notice(title: L("System account switched"), body: String(format: L("%1$@ now uses %2$@"), cliName, label))
        case let .failed(_, _, title, message):
            Notice(title: title, body: message)
        case .switching, nil:
            nil
        }
    }
}
