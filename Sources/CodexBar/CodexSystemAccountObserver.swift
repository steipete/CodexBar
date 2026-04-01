import CodexBarCore
import Foundation

struct ObservedSystemCodexAccount: Equatable, Sendable {
    let email: String
    let codexHomePath: String
    let observedAt: Date
    let identity: CodexIdentity

    init(
        email: String,
        codexHomePath: String,
        observedAt: Date,
        identity: CodexIdentity = .unresolved)
    {
        self.email = email
        self.codexHomePath = codexHomePath
        self.observedAt = observedAt
        self.identity = identity
    }
}

protocol CodexSystemAccountObserving: Sendable {
    func loadSystemAccount(environment: [String: String]) throws -> ObservedSystemCodexAccount?
}

struct DefaultCodexSystemAccountObserver: CodexSystemAccountObserving {
    func loadSystemAccount(environment: [String: String]) throws -> ObservedSystemCodexAccount? {
        let homeURL = CodexHomeScope.ambientHomeURL(env: environment)
        let fetcher = UsageFetcher(environment: environment)
        let account = fetcher.loadAuthBackedCodexAccount()

        guard let rawEmail = account.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawEmail.isEmpty
        else {
            return nil
        }

        return ObservedSystemCodexAccount(
            email: rawEmail.lowercased(),
            codexHomePath: homeURL.path,
            observedAt: Date(),
            identity: account.identity)
    }
}
