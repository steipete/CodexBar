import CodexBarCore
import Foundation

struct ObservedSystemCodexAccount: Equatable, Sendable {
    let email: String
    let workspaceLabel: String?
    let workspaceAccountID: String?
    let codexHomePath: String
    let observedAt: Date

    init(
        email: String,
        workspaceLabel: String? = nil,
        workspaceAccountID: String? = nil,
        codexHomePath: String,
        observedAt: Date)
    {
        self.email = email
        self.workspaceLabel = workspaceLabel
        self.workspaceAccountID = workspaceAccountID
        self.codexHomePath = codexHomePath
        self.observedAt = observedAt
    }
}

protocol CodexSystemAccountObserving: Sendable {
    func loadSystemAccount(environment: [String: String]) throws -> ObservedSystemCodexAccount?
}

struct DefaultCodexSystemAccountObserver: CodexSystemAccountObserving {
    func loadSystemAccount(environment: [String: String]) throws -> ObservedSystemCodexAccount? {
        let homeURL = CodexHomeScope.ambientHomeURL(env: environment)
        let fetcher = UsageFetcher(environment: environment)
        let info = fetcher.loadAccountInfo()

        guard let rawEmail = info.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawEmail.isEmpty
        else {
            return nil
        }

        return ObservedSystemCodexAccount(
            email: rawEmail.lowercased(),
            workspaceLabel: info.workspaceLabel,
            workspaceAccountID: info.workspaceAccountID,
            codexHomePath: homeURL.path,
            observedAt: Date())
    }
}
