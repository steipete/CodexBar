import CodexBarCore
import Foundation

struct PreparedIdentity: Sendable, Equatable {
    let email: String?
    let identity: CodexIdentity
    let providerAccountID: String?
    let workspaceLabel: String?
    let workspaceAccountID: String?
}

struct PreparedAuthMaterial: Sendable {
    let homeURL: URL
    let rawData: Data
    let credentials: CodexOAuthCredentials
    let runtimeAccount: CodexAuthBackedAccount
    let authIdentity: PreparedIdentity
}

enum PreparedManagedHomeState: Sendable {
    case readable(PreparedAuthMaterial)
    case missing(homeURL: URL)
    case unreadable(homeURL: URL)
}

struct PreparedStoredManagedAccount: Sendable {
    let persisted: ManagedCodexAccount
    let persistedIdentity: PreparedIdentity
    let homeState: PreparedManagedHomeState

    var authIdentity: PreparedIdentity? {
        switch self.homeState {
        case let .readable(authMaterial):
            authMaterial.authIdentity
        case .missing, .unreadable:
            nil
        }
    }
}

enum PreparedLiveHomeState: Sendable {
    case missing(homeURL: URL)
    case unreadable(homeURL: URL)
    case apiKeyOnly(PreparedAuthMaterial)
    case readable(PreparedAuthMaterial)
}

struct PreparedLiveAccount: Sendable {
    let homeState: PreparedLiveHomeState

    var homeURL: URL {
        switch self.homeState {
        case let .missing(homeURL), let .unreadable(homeURL):
            homeURL
        case let .apiKeyOnly(authMaterial), let .readable(authMaterial):
            authMaterial.homeURL
        }
    }

    var authIdentity: PreparedIdentity? {
        switch self.homeState {
        case let .apiKeyOnly(authMaterial), let .readable(authMaterial):
            authMaterial.authIdentity
        case .missing, .unreadable:
            nil
        }
    }
}

struct PreparedPromotionContext: Sendable {
    let snapshot: CodexAccountReconciliationSnapshot
    let managedAccounts: ManagedCodexAccountSet
    let storedManagedAccounts: [PreparedStoredManagedAccount]
    let target: PreparedStoredManagedAccount
    let live: PreparedLiveAccount
}

@MainActor
struct PreparedPromotionContextBuilder {
    private let store: any ManagedCodexAccountStoring
    private let workspaceResolver: any ManagedCodexWorkspaceResolving
    private let snapshotLoader: any CodexAccountReconciliationSnapshotLoading
    private let authMaterialReader: any CodexAuthMaterialReading
    private let baseEnvironment: [String: String]
    private let fileManager: FileManager

    init(
        store: any ManagedCodexAccountStoring,
        workspaceResolver: any ManagedCodexWorkspaceResolving,
        snapshotLoader: any CodexAccountReconciliationSnapshotLoading,
        authMaterialReader: any CodexAuthMaterialReading,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default)
    {
        self.store = store
        self.workspaceResolver = workspaceResolver
        self.snapshotLoader = snapshotLoader
        self.authMaterialReader = authMaterialReader
        self.baseEnvironment = baseEnvironment
        self.fileManager = fileManager
    }

    func build(targetID: UUID) async throws -> PreparedPromotionContext {
        let snapshot = self.snapshotLoader.loadSnapshot()
        let managedAccounts = try self.store.loadAccounts()
        var preparedAccounts: [PreparedStoredManagedAccount] = []
        preparedAccounts.reserveCapacity(managedAccounts.accounts.count)
        for account in managedAccounts.accounts {
            let preparedAccount = try await self.prepareStoredManagedAccount(account)
            preparedAccounts.append(preparedAccount)
        }

        guard let target = preparedAccounts.first(where: { $0.persisted.id == targetID }) else {
            throw CodexAccountPromotionError.targetManagedAccountNotFound
        }

        let live = await self.prepareLiveAccount()
        return PreparedPromotionContext(
            snapshot: snapshot,
            managedAccounts: managedAccounts,
            storedManagedAccounts: preparedAccounts,
            target: target,
            live: live)
    }

    private func prepareStoredManagedAccount(
        _ account: ManagedCodexAccount) async throws
        -> PreparedStoredManagedAccount
    {
        let homeURL = URL(fileURLWithPath: account.managedHomePath, isDirectory: true)
        let persistedIdentity = Self.persistedIdentity(from: account)
        let homeState = await self.prepareManagedHomeState(homeURL: homeURL)

        return PreparedStoredManagedAccount(
            persisted: account,
            persistedIdentity: persistedIdentity,
            homeState: homeState)
    }

    private func prepareManagedHomeState(homeURL: URL) async -> PreparedManagedHomeState {
        let readResult = self.readAuthData(homeURL: homeURL)
        switch readResult {
        case .missing:
            return .missing(homeURL: homeURL)
        case .unreadable:
            return .unreadable(homeURL: homeURL)
        case let .readable(rawData):
            guard let authMaterial = await self.inspectAuthMaterial(homeURL: homeURL, rawData: rawData) else {
                return .unreadable(homeURL: homeURL)
            }
            return .readable(authMaterial)
        }
    }

    private func prepareLiveAccount() async -> PreparedLiveAccount {
        let liveHomeURL = self.liveHomeURL()
        let readResult = self.readAuthData(homeURL: liveHomeURL)
        switch readResult {
        case .missing:
            return PreparedLiveAccount(homeState: .missing(homeURL: liveHomeURL))
        case .unreadable:
            return PreparedLiveAccount(homeState: .unreadable(homeURL: liveHomeURL))
        case let .readable(rawData):
            guard let authMaterial = await self.inspectAuthMaterial(homeURL: liveHomeURL, rawData: rawData) else {
                return PreparedLiveAccount(homeState: .unreadable(homeURL: liveHomeURL))
            }
            if Self.isAPIKeyOnly(credentials: authMaterial.credentials, rawData: authMaterial.rawData) {
                return PreparedLiveAccount(homeState: .apiKeyOnly(authMaterial))
            }
            return PreparedLiveAccount(homeState: .readable(authMaterial))
        }
    }

    private func inspectAuthMaterial(homeURL: URL, rawData: Data) async -> PreparedAuthMaterial? {
        guard let credentials = try? CodexOAuthCredentialsStore.parse(data: rawData),
              let runtimeAccount = try? Self.runtimeAccount(from: rawData)
        else {
            return nil
        }

        let authIdentity = await self.derivedIdentity(
            homePath: homeURL.path,
            runtimeAccount: runtimeAccount)

        return PreparedAuthMaterial(
            homeURL: homeURL,
            rawData: rawData,
            credentials: credentials,
            runtimeAccount: runtimeAccount,
            authIdentity: authIdentity)
    }

    private func derivedIdentity(homePath: String, runtimeAccount: CodexAuthBackedAccount) async -> PreparedIdentity {
        let normalizedEmail = Self.normalizeEmail(runtimeAccount.email)
        let normalizedIdentity = Self.normalizedIdentity(runtimeAccount.identity, email: normalizedEmail)
        let providerAccountID: String? = switch normalizedIdentity {
        case let .providerAccount(id):
            ManagedCodexAccount.normalizeProviderAccountID(id)
        case .emailOnly, .unresolved:
            nil
        }
        let workspaceIdentity: CodexOpenAIWorkspaceIdentity? = if let providerAccountID {
            await self.workspaceResolver.resolveWorkspaceIdentity(
                homePath: homePath,
                providerAccountID: providerAccountID)
        } else {
            nil
        }

        return PreparedIdentity(
            email: normalizedEmail,
            identity: normalizedIdentity,
            providerAccountID: providerAccountID,
            workspaceLabel: workspaceIdentity?.workspaceLabel,
            workspaceAccountID: workspaceIdentity?.workspaceAccountID ?? providerAccountID)
    }

    private static func persistedIdentity(from account: ManagedCodexAccount) -> PreparedIdentity {
        let normalizedEmail = Self.normalizeEmail(account.email)
        let providerAccountID = ManagedCodexAccount.normalizeProviderAccountID(account.providerAccountID)
        let identity = Self.normalizedIdentity(
            CodexIdentityResolver.resolve(accountId: providerAccountID, email: normalizedEmail),
            email: normalizedEmail)

        return PreparedIdentity(
            email: normalizedEmail,
            identity: identity,
            providerAccountID: providerAccountID,
            workspaceLabel: account.workspaceLabel,
            workspaceAccountID: account.workspaceAccountID)
    }

    private func liveHomeURL() -> URL {
        CodexHomeScope.ambientHomeURL(env: self.baseEnvironment, fileManager: self.fileManager)
    }

    private func readAuthData(homeURL: URL) -> PreparedAuthReadState {
        do {
            let rawData = try self.authMaterialReader.readAuthData(homeURL: homeURL)
            guard let rawData else {
                return .missing
            }
            return .readable(rawData)
        } catch {
            return .unreadable
        }
    }

    private static func runtimeAccount(from rawData: Data) throws -> CodexAuthBackedAccount {
        guard let json = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            throw CodexOAuthCredentialsError.decodeFailed("Invalid JSON")
        }

        let tokens = json["tokens"] as? [String: Any]
        let idToken = tokens.flatMap {
            Self.nonEmptyString(in: $0, snakeCaseKey: "id_token", camelCaseKey: "idToken")
        }
        let payload = idToken.flatMap(UsageFetcher.parseJWT)
        let authDict = payload?["https://api.openai.com/auth"] as? [String: Any]
        let profileDict = payload?["https://api.openai.com/profile"] as? [String: Any]

        let email = Self.normalizeEmail(
            (payload?["email"] as? String) ?? (profileDict?["email"] as? String))
        let plan = Self.normalizedField(
            (authDict?["chatgpt_plan_type"] as? String) ?? (payload?["chatgpt_plan_type"] as? String))
        let accountID = ManagedCodexAccount.normalizeProviderAccountID(
            tokens.flatMap {
                Self.nonEmptyString(in: $0, snakeCaseKey: "account_id", camelCaseKey: "accountId")
            }
                ?? (authDict?["chatgpt_account_id"] as? String)
                ?? (payload?["chatgpt_account_id"] as? String))
        let identity = Self.normalizedIdentity(
            CodexIdentityResolver.resolve(accountId: accountID, email: email),
            email: email)

        return CodexAuthBackedAccount(identity: identity, email: email, plan: plan)
    }

    private static func normalizedField(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizeEmail(_ email: String?) -> String? {
        CodexIdentityResolver.normalizeEmail(email)
    }

    private static func normalizedIdentity(_ identity: CodexIdentity, email: String?) -> CodexIdentity {
        guard let email else { return identity }
        return CodexIdentityMatcher.normalized(identity, fallbackEmail: email)
    }

    private static func isAPIKeyOnly(credentials: CodexOAuthCredentials, rawData: Data) -> Bool {
        guard self.hasUsableOAuthTokens(in: rawData) == false else {
            return false
        }
        return credentials.refreshToken.isEmpty
            && credentials.idToken == nil
            && credentials.accountId == nil
            && credentials.lastRefresh == nil
    }

    private static func hasUsableOAuthTokens(in rawData: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any]
        else {
            return false
        }
        let accessToken = self.nonEmptyString(
            in: tokens,
            snakeCaseKey: "access_token",
            camelCaseKey: "accessToken")
        let refreshToken = self.nonEmptyString(
            in: tokens,
            snakeCaseKey: "refresh_token",
            camelCaseKey: "refreshToken")
        return accessToken != nil && refreshToken != nil
    }

    private static func nonEmptyString(
        in dictionary: [String: Any],
        snakeCaseKey: String,
        camelCaseKey: String)
        -> String?
    {
        if let value = dictionary[snakeCaseKey] as? String,
           value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
            return value
        }
        if let value = dictionary[camelCaseKey] as? String,
           value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
            return value
        }
        return nil
    }
}

private enum PreparedAuthReadState {
    case missing
    case unreadable
    case readable(Data)
}
