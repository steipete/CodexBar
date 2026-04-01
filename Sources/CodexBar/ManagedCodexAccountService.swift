import CodexBarCore
import Foundation

protocol ManagedCodexHomeProducing: Sendable {
    func makeHomeURL() -> URL
    func validateManagedHomeForDeletion(_ url: URL) throws
}

protocol ManagedCodexLoginRunning: Sendable {
    func run(homePath: String, timeout: TimeInterval) async -> CodexLoginRunner.Result
}

protocol ManagedCodexIdentityReading: Sendable {
    func loadAccountIdentity(homePath: String) throws -> CodexAuthBackedAccount
}

enum ManagedCodexAccountServiceError: Error, Equatable, Sendable {
    case loginFailed
    case missingEmail
    case unsafeManagedHome(String)
}

struct ManagedCodexHomeFactory: ManagedCodexHomeProducing, Sendable {
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
            throw ManagedCodexAccountServiceError.unsafeManagedHome(url.path)
        }
    }

    static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("managed-codex-homes", isDirectory: true)
    }
}

struct DefaultManagedCodexLoginRunner: ManagedCodexLoginRunning {
    func run(homePath: String, timeout: TimeInterval) async -> CodexLoginRunner.Result {
        await CodexLoginRunner.run(homePath: homePath, timeout: timeout)
    }
}

struct DefaultManagedCodexIdentityReader: ManagedCodexIdentityReading {
    func loadAccountIdentity(homePath: String) throws -> CodexAuthBackedAccount {
        let env = CodexHomeScope.scopedEnvironment(
            base: ProcessInfo.processInfo.environment,
            codexHome: homePath)
        return UsageFetcher(environment: env).loadAuthBackedCodexAccount()
    }
}

@MainActor
final class ManagedCodexAccountService {
    private let store: any ManagedCodexAccountStoring
    private let homeFactory: any ManagedCodexHomeProducing
    private let loginRunner: any ManagedCodexLoginRunning
    private let identityReader: any ManagedCodexIdentityReading
    private let fileManager: FileManager

    init(
        store: any ManagedCodexAccountStoring,
        homeFactory: any ManagedCodexHomeProducing,
        loginRunner: any ManagedCodexLoginRunning,
        identityReader: any ManagedCodexIdentityReading,
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
            store: FileManagedCodexAccountStore(fileManager: fileManager),
            homeFactory: ManagedCodexHomeFactory(fileManager: fileManager),
            loginRunner: DefaultManagedCodexLoginRunner(),
            identityReader: DefaultManagedCodexIdentityReader(),
            fileManager: fileManager)
    }

    func authenticateManagedAccount(
        existingAccountID: UUID? = nil,
        timeout: TimeInterval = 120)
        async throws -> ManagedCodexAccount
    {
        let snapshot = try self.store.loadAccounts()
        let homeURL = self.homeFactory.makeHomeURL()
        try self.fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let account: ManagedCodexAccount
        let existingHomePathToDelete: String?

        do {
            let result = await self.loginRunner.run(homePath: homeURL.path, timeout: timeout)
            guard case .success = result.outcome else { throw ManagedCodexAccountServiceError.loginFailed }

            let identity = try self.identityReader.loadAccountIdentity(homePath: homeURL.path)
            guard let rawEmail = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawEmail.isEmpty
            else {
                throw ManagedCodexAccountServiceError.missingEmail
            }

            let now = Date().timeIntervalSince1970
            let existing = self.reconciledExistingAccount(
                authenticatedEmail: rawEmail,
                existingAccountID: existingAccountID,
                snapshot: snapshot)

            account = ManagedCodexAccount(
                id: existing?.id ?? UUID(),
                email: rawEmail,
                managedHomePath: homeURL.path,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                lastAuthenticatedAt: now)
            existingHomePathToDelete = existing?.managedHomePath

            let updatedSnapshot = ManagedCodexAccountSet(
                version: snapshot.version,
                accounts: snapshot.accounts.filter { $0.id != account.id && $0.email != account.email } + [account])
            try self.store.storeAccounts(updatedSnapshot)
        } catch {
            try? self.removeManagedHomeIfSafe(atPath: homeURL.path)
            throw error
        }

        if let existingHomePathToDelete, existingHomePathToDelete != homeURL.path {
            try? self.removeManagedHomeIfSafe(atPath: existingHomePathToDelete)
        }
        return account
    }

    func removeManagedAccount(id: UUID) async throws {
        let snapshot = try self.store.loadAccounts()
        guard let account = snapshot.account(id: id) else { return }

        let homeURL = URL(fileURLWithPath: account.managedHomePath, isDirectory: true)
        try self.homeFactory.validateManagedHomeForDeletion(homeURL)

        let remaining = snapshot.accounts.filter { $0.id != id }
        try self.store.storeAccounts(ManagedCodexAccountSet(
            version: snapshot.version,
            accounts: remaining))

        if self.fileManager.fileExists(atPath: homeURL.path) {
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
        snapshot: ManagedCodexAccountSet)
        -> ManagedCodexAccount?
    {
        if let existingByEmail = snapshot.account(email: authenticatedEmail) {
            return existingByEmail
        }
        guard let existingAccountID else { return nil }
        guard let existingByID = snapshot.account(id: existingAccountID) else { return nil }
        return existingByID.email == Self.normalizeEmail(authenticatedEmail) ? existingByID : nil
    }

    private static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
