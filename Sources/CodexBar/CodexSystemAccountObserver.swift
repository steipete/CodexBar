import CodexBarCore
import Foundation

struct ObservedSystemCodexAccount: Equatable, Sendable {
    let email: String
    let codexHomePath: String
    let observedAt: Date
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
            codexHomePath: homeURL.path,
            observedAt: Date())
    }
}
