import Foundation

public struct ObservedSystemCodexAccount: Equatable, Sendable {
    public let email: String
    public let workspaceLabel: String?
    public let workspaceAccountID: String?
    public let codexHomePath: String
    public let observedAt: Date
    public let identity: CodexIdentity

    public init(
        email: String,
        workspaceLabel: String? = nil,
        workspaceAccountID: String? = nil,
        codexHomePath: String,
        observedAt: Date,
        identity: CodexIdentity = .unresolved)
    {
        self.email = email
        self.workspaceLabel = workspaceLabel
        self.workspaceAccountID = workspaceAccountID
        self.codexHomePath = codexHomePath
        self.observedAt = observedAt
        self.identity = identity
    }
}

public protocol CodexSystemAccountObserving: Sendable {
    func loadSystemAccount(environment: [String: String]) throws -> ObservedSystemCodexAccount?
}

public struct DefaultCodexSystemAccountObserver: CodexSystemAccountObserving {
    private let workspaceCache: CodexOpenAIWorkspaceIdentityCache

    public init(workspaceCache: CodexOpenAIWorkspaceIdentityCache = CodexOpenAIWorkspaceIdentityCache()) {
        self.workspaceCache = workspaceCache
    }

    public func loadSystemAccount(environment: [String: String]) throws -> ObservedSystemCodexAccount? {
        let homeURL = CodexHomeScope.ambientHomeURL(env: environment)
        let fetcher = UsageFetcher(environment: environment)
        let account = fetcher.loadAuthBackedCodexAccount()

        guard let rawEmail = account.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawEmail.isEmpty
        else {
            return nil
        }

        let providerAccountID: String? = switch account.identity {
        case let .providerAccount(id):
            ManagedCodexAccount.normalizeProviderAccountID(id)
        case .emailOnly, .unresolved:
            nil
        }

        return ObservedSystemCodexAccount(
            email: rawEmail.lowercased(),
            workspaceLabel: self.workspaceCache.workspaceLabel(for: providerAccountID),
            workspaceAccountID: providerAccountID,
            codexHomePath: homeURL.path,
            observedAt: Date(),
            identity: account.identity)
    }
}
