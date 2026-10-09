import Foundation

package struct PreparedIdentity: Equatable {
    package let email: String?
    package let identity: CodexIdentity
    package let providerAccountID: String?
    package let workspaceLabel: String?
    package let workspaceAccountID: String?
}

package struct PreparedAuthMaterial {
    package let homeURL: URL
    package let rawData: Data
    package let credentials: CodexOAuthCredentials
    package let authIdentity: PreparedIdentity
}

package enum PreparedManagedHomeState {
    case readable(PreparedAuthMaterial)
    case missing(homeURL: URL)
    case unreadable(homeURL: URL)
}

package struct PreparedStoredManagedAccount {
    package let persisted: ManagedCodexAccount
    package let persistedIdentity: PreparedIdentity
    package let homeState: PreparedManagedHomeState

    package var authIdentity: PreparedIdentity? {
        switch self.homeState {
        case let .readable(authMaterial):
            authMaterial.authIdentity
        case .missing, .unreadable:
            nil
        }
    }

    package var remoteIdentity: PreparedIdentity {
        guard let workspaceAccountID = self.persisted.effectiveWorkspaceAccountID else {
            return self.authIdentity ?? self.persistedIdentity
        }
        return PreparedIdentity(
            email: self.authIdentity?.email ?? self.persistedIdentity.email,
            identity: .providerAccount(id: workspaceAccountID),
            providerAccountID: workspaceAccountID,
            workspaceLabel: self.persistedIdentity.workspaceLabel ?? self.authIdentity?.workspaceLabel,
            workspaceAccountID: workspaceAccountID)
    }

    package var selectedWorkspaceDiffersFromAuthDefault: Bool {
        guard let selectedWorkspaceAccountID = self.persisted.effectiveWorkspaceAccountID,
              let authIdentity = self.authIdentity
        else {
            return false
        }
        return selectedWorkspaceAccountID != ManagedCodexAccount.normalizeWorkspaceAccountID(
            authIdentity.providerAccountID)
    }
}

package enum PreparedLiveHomeState {
    case missing(homeURL: URL)
    case unreadable(homeURL: URL)
    case apiKeyOnly(PreparedAuthMaterial)
    case readable(PreparedAuthMaterial)
}

package struct PreparedLiveAccount {
    package let homeState: PreparedLiveHomeState

    package var homeURL: URL {
        switch self.homeState {
        case let .missing(homeURL), let .unreadable(homeURL):
            homeURL
        case let .apiKeyOnly(authMaterial), let .readable(authMaterial):
            authMaterial.homeURL
        }
    }

    package var authIdentity: PreparedIdentity? {
        switch self.homeState {
        case let .apiKeyOnly(authMaterial), let .readable(authMaterial):
            authMaterial.authIdentity
        case .missing, .unreadable:
            nil
        }
    }
}

package struct PreparedPromotionContext {
    package let snapshot: CodexAccountReconciliationSnapshot?
    package let storedManagedAccounts: [PreparedStoredManagedAccount]
    package let target: PreparedStoredManagedAccount
    package let live: PreparedLiveAccount
}

@MainActor
package struct PreparedPromotionContextBuilder {
    package let store: any ManagedCodexAccountStoring
    package let workspaceResolver: (any ManagedCodexWorkspaceResolving)?
    package let snapshotLoader: (any CodexAccountReconciliationSnapshotLoading)?
    package let authMaterialReader: any CodexAuthMaterialReading
    @ProcessEnvironment private(set) var baseEnvironment: [String: String]
    package let fileManager: FileManager

    package func build(targetID: UUID) async throws -> PreparedPromotionContext {
        let snapshot = self.snapshotLoader?.loadSnapshot()
        let managedAccounts = try self.store.loadAccounts()
        var preparedAccounts: [PreparedStoredManagedAccount] = []
        preparedAccounts.reserveCapacity(managedAccounts.accounts.count)
        for account in managedAccounts.accounts {
            await preparedAccounts.append(PreparedStoredManagedAccount(
                persisted: account,
                persistedIdentity: Self.persistedIdentity(from: account),
                homeState: self.prepareManagedHomeState(
                    homeURL: URL(fileURLWithPath: account.managedHomePath, isDirectory: true))))
        }

        guard let target = preparedAccounts.first(where: { $0.persisted.id == targetID }) else {
            throw CodexAccountPromotionError.targetManagedAccountNotFound
        }

        let live = await self.prepareLiveAccount()
        return PreparedPromotionContext(
            snapshot: snapshot,
            storedManagedAccounts: preparedAccounts,
            target: target,
            live: live)
    }

    private func prepareManagedHomeState(homeURL: URL) async -> PreparedManagedHomeState {
        do {
            guard let rawData = try self.authMaterialReader.readAuthData(homeURL: homeURL) else {
                return .missing(homeURL: homeURL)
            }
            guard let authMaterial = await self.inspectAuthMaterial(homeURL: homeURL, rawData: rawData) else {
                return .unreadable(homeURL: homeURL)
            }
            return .readable(authMaterial)
        } catch {
            return .unreadable(homeURL: homeURL)
        }
    }

    private func prepareLiveAccount() async -> PreparedLiveAccount {
        let liveHomeURL = CodexHomeScope.ambientHomeURL(env: self.baseEnvironment, fileManager: self.fileManager)
        let homeState: PreparedLiveHomeState = switch await self.prepareManagedHomeState(homeURL: liveHomeURL) {
        case .missing: .missing(homeURL: liveHomeURL)
        case .unreadable: .unreadable(homeURL: liveHomeURL)
        case let .readable(material):
            if Self.isAPIKeyOnly(credentials: material.credentials, rawData: material.rawData) {
                .apiKeyOnly(material)
            } else {
                .readable(material)
            }
        }
        return PreparedLiveAccount(homeState: homeState)
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
            authIdentity: authIdentity)
    }

    private func derivedIdentity(homePath: String, runtimeAccount: CodexAuthBackedAccount) async -> PreparedIdentity {
        let normalizedEmail = CodexIdentityResolver.normalizeEmail(runtimeAccount.email)
        let normalizedIdentity = Self.normalizedIdentity(runtimeAccount.identity, email: normalizedEmail)
        let providerAccountID: String? = switch normalizedIdentity {
        case let .providerAccount(id):
            ManagedCodexAccount.normalizeWorkspaceAccountID(id)
        case .emailOnly, .unresolved:
            nil
        }
        let workspaceIdentity: CodexOpenAIWorkspaceIdentity? = if let providerAccountID {
            await self.workspaceResolver?.resolveWorkspaceIdentity(
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
        let normalizedEmail = CodexIdentityResolver.normalizeEmail(account.email)
        let providerAccountID = account.effectiveWorkspaceAccountID
        let identity = Self.normalizedIdentity(
            CodexIdentityResolver.resolve(accountId: providerAccountID, email: normalizedEmail),
            email: normalizedEmail)

        return PreparedIdentity(
            email: normalizedEmail,
            identity: identity,
            providerAccountID: providerAccountID,
            workspaceLabel: account.workspaceLabel,
            workspaceAccountID: providerAccountID)
    }

    package nonisolated static func runtimeAccount(from rawData: Data) throws -> CodexAuthBackedAccount {
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

        // Promotion preserves its established top-level email precedence. Credential release applies
        // the stricter owner-evidence policy in CodexNativeCredentialOwnerIdentity instead.
        let email = CodexIdentityResolver.normalizeEmail(
            (payload?["email"] as? String) ?? (profileDict?["email"] as? String))
        let plan = Self.normalizedField(
            (authDict?["chatgpt_plan_type"] as? String) ?? (payload?["chatgpt_plan_type"] as? String))
        let accountID = ManagedCodexAccount.normalizeWorkspaceAccountID(
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

    private nonisolated static func normalizedField(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private nonisolated static func normalizedIdentity(_ identity: CodexIdentity, email: String?) -> CodexIdentity {
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

    private nonisolated static func nonEmptyString(
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
