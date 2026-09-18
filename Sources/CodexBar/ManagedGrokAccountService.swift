import CodexBarCore
import Foundation

protocol ManagedGrokHomeProducing: Sendable {
    func makeHomeURL() -> URL
    func validateManagedHomeForDeletion(_ url: URL) throws
}

protocol ManagedGrokLoginRunning: Sendable {
    func run(
        homePath: String,
        timeout: TimeInterval,
        onProgress: (@Sendable (String) -> Void)?) async -> CLILoginRunner.Result
}

protocol ManagedGrokIdentityReading: Sendable {
    func loadAccountIdentity(homePath: String) throws -> GrokCredentials
}

enum ManagedGrokAccountServiceError: Error, Equatable {
    case loginFailed(CLILoginRunner.Result)
    case missingEmail
    case unsafeManagedHome(String)
}

extension ManagedGrokAccountServiceError {
    var userFacingMessage: String {
        switch self {
        case let .loginFailed(result):
            GrokLoginAlertPresentation.managedLoginFailureMessage(for: result)
        case .missingEmail:
            L("managed_grok_login_missing_email")
        case let .unsafeManagedHome(path):
            String(format: L("unsafe_managed_home"), path)
        }
    }
}

struct ManagedGrokHomeFactory: ManagedGrokHomeProducing {
    let root: URL

    init(root: URL = Self.defaultRootURL(), fileManager: FileManager = .default) {
        let standardizedRoot = root.standardizedFileURL
        if standardizedRoot.path != root.path {
            self.root = standardizedRoot
        } else {
            self.root = root
        }
        _ = fileManager
    }

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        let rootPath = self.root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(rootPrefix), targetPath != rootPath else {
            throw ManagedGrokAccountServiceError.unsafeManagedHome(url.path)
        }
    }

    static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("managed-grok-homes", isDirectory: true)
    }
}

struct DefaultManagedGrokLoginRunner: ManagedGrokLoginRunning {
    func run(
        homePath: String,
        timeout: TimeInterval,
        onProgress: (@Sendable (String) -> Void)?) async -> CLILoginRunner.Result
    {
        await GrokLoginRunner.run(homePath: homePath, timeout: timeout, onProgress: onProgress)
    }
}

struct DefaultManagedGrokIdentityReader: ManagedGrokIdentityReading {
    func loadAccountIdentity(homePath: String) throws -> GrokCredentials {
        try GrokCredentialsStore.load(env: ["GROK_HOME": homePath])
    }
}

@MainActor
final class ManagedGrokAccountService {
    private let store: any ManagedGrokAccountStoring
    private let homeFactory: any ManagedGrokHomeProducing
    private let loginRunner: any ManagedGrokLoginRunning
    private let identityReader: any ManagedGrokIdentityReading
    private let fileManager: FileManager

    init(
        store: any ManagedGrokAccountStoring,
        homeFactory: any ManagedGrokHomeProducing,
        loginRunner: any ManagedGrokLoginRunning,
        identityReader: any ManagedGrokIdentityReading,
        fileManager: FileManager = .default)
    {
        self.store = store
        self.homeFactory = homeFactory
        self.loginRunner = loginRunner
        self.identityReader = identityReader
        self.fileManager = fileManager
    }

    convenience init(fileManager: FileManager = .default) {
        self.init(
            store: FileManagedGrokAccountStore(fileManager: fileManager),
            homeFactory: ManagedGrokHomeFactory(fileManager: fileManager),
            loginRunner: DefaultManagedGrokLoginRunner(),
            identityReader: DefaultManagedGrokIdentityReader(),
            fileManager: fileManager)
    }

    func authenticateManagedAccount(
        existingAccountID: UUID? = nil,
        timeout: TimeInterval = GrokLoginRunner.defaultTimeout,
        onProgress: (@Sendable (String) -> Void)? = nil) async throws -> ManagedGrokAccount
    {
        let snapshot = try self.store.loadAccounts()
        let homeURL = self.homeFactory.makeHomeURL()
        try self.fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let account: ManagedGrokAccount
        let existingHomePathsToDelete: [String]

        do {
            let result = await self.loginRunner.run(homePath: homeURL.path, timeout: timeout, onProgress: onProgress)
            guard case .success = result.outcome else { throw ManagedGrokAccountServiceError.loginFailed(result) }

            let identity = try self.identityReader.loadAccountIdentity(homePath: homeURL.path)
            guard let rawEmail = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawEmail.isEmpty
            else {
                throw ManagedGrokAccountServiceError.missingEmail
            }

            let now = Date().timeIntervalSince1970
            let existing = self.reconciledExistingAccount(
                authenticatedEmail: rawEmail,
                existingAccountID: existingAccountID,
                snapshot: snapshot)
            account = ManagedGrokAccount(
                id: existing?.id ?? UUID(),
                email: rawEmail,
                userID: identity.userId,
                managedHomePath: homeURL.path,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                lastAuthenticatedAt: now)
            let replacedAccountIDs = self.replacedAccountIDs(
                authenticatedEmail: rawEmail,
                existingAccountID: existingAccountID,
                matchedAccountID: existing?.id,
                snapshot: snapshot)
            existingHomePathsToDelete = snapshot.accounts
                .filter { replacedAccountIDs.contains($0.id) }
                .map(\.managedHomePath)

            let updatedSnapshot = ManagedGrokAccountSet(
                version: snapshot.version,
                accounts: snapshot.accounts.filter { replacedAccountIDs.contains($0.id) == false } + [account])
            try self.store.storeAccounts(updatedSnapshot)
        } catch {
            try? self.removeManagedHomeIfSafe(atPath: homeURL.path)
            throw error
        }

        for existingHomePathToDelete in existingHomePathsToDelete where existingHomePathToDelete != homeURL.path {
            try? self.removeManagedHomeIfSafe(atPath: existingHomePathToDelete)
        }
        return account
    }

    func removeManagedAccount(id: UUID) async throws {
        let snapshot = try self.store.loadAccounts()
        guard let account = snapshot.account(id: id) else { return }

        let homeURL = URL(fileURLWithPath: account.managedHomePath, isDirectory: true)
        let canDeleteHome = (try? self.homeFactory.validateManagedHomeForDeletion(homeURL)) != nil

        let remaining = snapshot.accounts.filter { $0.id != id }
        try self.store.storeAccounts(ManagedGrokAccountSet(
            version: snapshot.version,
            accounts: remaining))

        if canDeleteHome, self.fileManager.fileExists(atPath: homeURL.path) {
            try? self.fileManager.removeItem(at: homeURL)
        }
    }

    private func removeManagedHomeIfSafe(atPath path: String) throws {
        let homeURL = URL(fileURLWithPath: path, isDirectory: true)
        try self.homeFactory.validateManagedHomeForDeletion(homeURL)
        if self.fileManager.fileExists(atPath: homeURL.path) {
            try self.fileManager.removeItem(at: homeURL)
        }
    }

    private func reconciledExistingAccount(
        authenticatedEmail: String,
        existingAccountID: UUID?,
        snapshot: ManagedGrokAccountSet) -> ManagedGrokAccount?
    {
        let normalizedEmail = ManagedGrokAccount.normalizeEmail(authenticatedEmail)
        if let existingAccountID, let existing = snapshot.account(id: existingAccountID) {
            return existing
        }
        return snapshot.accounts.first { $0.email == normalizedEmail }
    }

    private func replacedAccountIDs(
        authenticatedEmail: String,
        existingAccountID: UUID?,
        matchedAccountID: UUID?,
        snapshot: ManagedGrokAccountSet) -> Set<UUID>
    {
        let normalizedEmail = ManagedGrokAccount.normalizeEmail(authenticatedEmail)
        var ids = Set(snapshot.accounts.filter { $0.email == normalizedEmail }.map(\.id))
        if let existingAccountID {
            ids.insert(existingAccountID)
        }
        if let matchedAccountID {
            ids.insert(matchedAccountID)
        }
        return ids
    }
}
