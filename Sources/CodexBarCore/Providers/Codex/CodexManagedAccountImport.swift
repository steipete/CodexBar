#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

package enum CodexManagedAccountImportOutcome: String, Equatable, Sendable {
    case imported
    case existing
}

/// Safe import result. It never carries credential contents, tokens, fingerprints, or home paths.
package struct CodexManagedAccountImportReceipt: Equatable, Sendable {
    package let id: UUID
    package let email: String
    package let outcome: CodexManagedAccountImportOutcome
}

package enum CodexManagedAccountImportError: Error, Equatable, LocalizedError {
    case sourcePathNotAbsolute
    case sourceAuthMissing
    case sourceAuthUnsafe
    case sourceAuthTooLarge
    case sourceAuthUnreadable
    case sourceNotOAuth
    case sourceMissingEmail
    case sourceMissingWorkspaceIdentity
    case accountExists
    case unsafeManagedHome
    case managedHomeWriteFailed
    case registryCommitFailed

    package var errorDescription: String? {
        switch self {
        case .sourcePathNotAbsolute: "Profile home must be an absolute path without '..' components."
        case .sourceAuthMissing: "No auth.json found in the profile home."
        case .sourceAuthUnsafe: "Profile auth.json must be a regular file owned by the current user (no symlinks)."
        case .sourceAuthTooLarge: "Profile auth.json is unexpectedly large."
        case .sourceAuthUnreadable: "Profile auth.json could not be read."
        case .sourceNotOAuth: "Profile auth.json has no usable OAuth tokens (API-key-only profiles are not imported)."
        case .sourceMissingEmail: "Profile authentication does not identify an account email."
        case .sourceMissingWorkspaceIdentity: "Profile authentication does not identify a provider workspace account."
        case .accountExists:
            "A managed account for this email and workspace already exists with different credentials. "
                + "Nothing was changed."
        case .unsafeManagedHome: "Managed account home location is not safe to create."
        case .managedHomeWriteFailed: "Could not write the managed account home."
        case .registryCommitFailed: "Could not save the managed account registry. Nothing was imported."
        }
    }
}

/// Reads exactly one regular, owner-owned, non-symlink `auth.json` of bounded size from a profile home.
package struct CodexImportSourceAuthReader: CodexAuthMaterialReading {
    package static let maximumBytes = 256 * 1024

    package init() {}

    package func readAuthData(homeURL: URL) throws -> Data? {
        let url = CodexAuthFingerprint.authFileURL(homePath: homeURL.path)
        guard CodexCredentialFileAccess.permits(url) else { throw CodexManagedAccountImportError.sourceAuthMissing }
        var linkStatus = stat()
        guard url.path.withCString({ lstat($0, &linkStatus) }) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw CodexManagedAccountImportError.sourceAuthUnreadable
        }
        guard linkStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), linkStatus.st_uid == getuid() else {
            throw CodexManagedAccountImportError.sourceAuthUnsafe
        }
        guard linkStatus.st_size <= Self.maximumBytes else { throw CodexManagedAccountImportError.sourceAuthTooLarge }
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw CodexManagedAccountImportError.sourceAuthUnsafe }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var openStatus = stat()
        guard fstat(descriptor, &openStatus) == 0, openStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              openStatus.st_uid == getuid(), openStatus.st_ino == linkStatus.st_ino,
              openStatus.st_dev == linkStatus.st_dev
        else { throw CodexManagedAccountImportError.sourceAuthUnsafe }
        let data: Data
        do { data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data() } catch {
            throw CodexManagedAccountImportError.sourceAuthUnreadable
        }
        guard data.count <= Self.maximumBytes else { throw CodexManagedAccountImportError.sourceAuthTooLarge }
        return data
    }
}

/// Copies an existing OAuth `auth.json` into a new private managed home and registers it.
///
/// This never touches system (ambient) authentication, starts login, resolves workspaces over the network,
/// or reads the Keychain. The source home is only read. The registry lock is held across read, validation,
/// home creation and registry write.
package struct CodexManagedAccountImportTransaction {
    private struct Validated {
        let data: Data
        let email: String
        let workspaceAccountID: String
        let fingerprint: String
    }

    private let store: any ManagedCodexAccountStoring
    private let homeFactory: any ManagedCodexHomeProducing
    private let authMaterialReader: any CodexAuthMaterialReading
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    package init(
        store: any ManagedCodexAccountStoring,
        homeFactory: any ManagedCodexHomeProducing,
        authMaterialReader: any CodexAuthMaterialReading = CodexImportSourceAuthReader(),
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default)
    {
        self.store = store
        self.homeFactory = homeFactory
        self.authMaterialReader = authMaterialReader
        self.now = now
        self.fileManager = fileManager
    }

    /// Validates user-typed path text before it is converted to a URL: absolute, no `..` components.
    package static func validateRawSourcePath(_ raw: String) throws -> URL {
        guard raw.hasPrefix("/"), !raw.split(separator: "/", omittingEmptySubsequences: true).contains("..") else {
            throw CodexManagedAccountImportError.sourcePathNotAbsolute
        }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    package func importProfile(fromHome sourceHome: URL) throws -> CodexManagedAccountImportReceipt {
        // URL(fileURLWithPath:) resolves relative input against the cwd, so callers must validate raw user
        // text (see `validateRawSourcePath`). Here only an explicit traversal component is refused.
        guard sourceHome.isFileURL, !sourceHome.pathComponents.contains("..") else {
            throw CodexManagedAccountImportError.sourcePathNotAbsolute
        }
        let home = sourceHome.standardizedFileURL
        return try ManagedCodexAccountLock.withLock(at: self.store.lockURL) {
            try FileManagedCodexAccountStore.$mutation.withValue(.addOrReauth) {
                try self.importLocked(sourceHome: home)
            }
        }
    }

    private func importLocked(sourceHome: URL) throws -> CodexManagedAccountImportReceipt {
        guard let data = try self.authMaterialReader.readAuthData(homeURL: sourceHome) else {
            throw CodexManagedAccountImportError.sourceAuthMissing
        }
        let source = try Self.validate(data)
        let existing = try self.store.loadAccounts()

        if let match = existing.accounts.first(where: {
            $0.email == source.email && $0.effectiveWorkspaceAccountID == source.workspaceAccountID
        }) {
            guard self.managedAuthMatches(match, fingerprint: source.fingerprint) else {
                throw CodexManagedAccountImportError.accountExists
            }
            return CodexManagedAccountImportReceipt(id: match.id, email: match.email, outcome: .existing)
        }
        // A legacy email-only record is ambiguous with this workspace; never shadow it.
        guard !existing.accounts.contains(where: {
            $0.email == source.email && $0.effectiveWorkspaceAccountID == nil
        }) else { throw CodexManagedAccountImportError.accountExists }

        let homeURL = self.homeFactory.makeHomeURL()
        guard let id = UUID(uuidString: homeURL.lastPathComponent),
              CodexCredentialFileAccess.permits(CodexAuthFingerprint.authFileURL(homePath: homeURL.path)),
              (try? self.homeFactory.validateManagedHomeForDeletion(homeURL)) != nil,
              !existing.accounts.contains(where: { $0.id == id || Self.samePath($0.managedHomePath, homeURL.path) })
        else { throw CodexManagedAccountImportError.unsafeManagedHome }

        var createdHome = false
        do {
            try self.createPrivateHome(homeURL)
            createdHome = true
            try self.writeAndVerify(source, to: homeURL)
            let timestamp = self.now().timeIntervalSince1970
            let account = ManagedCodexAccount(
                id: id,
                email: source.email,
                providerAccountID: source.workspaceAccountID,
                workspaceAccountID: source.workspaceAccountID,
                authFingerprint: source.fingerprint,
                managedHomePath: homeURL.path,
                createdAt: timestamp,
                updatedAt: timestamp,
                lastAuthenticatedAt: timestamp)
            do {
                try self.store.storeAccounts(ManagedCodexAccountSet(
                    version: FileManagedCodexAccountStore.currentVersion,
                    accounts: existing.accounts + [account]))
            } catch {
                throw CodexManagedAccountImportError.registryCommitFailed
            }
            guard (try? self.store.loadAccounts())?.account(id: id) != nil else {
                throw CodexManagedAccountImportError.registryCommitFailed
            }
            return CodexManagedAccountImportReceipt(id: id, email: source.email, outcome: .imported)
        } catch {
            if createdHome { self.removeHomeIfUnreferenced(homeURL, id: id) }
            throw error as? CodexManagedAccountImportError ?? CodexManagedAccountImportError.managedHomeWriteFailed
        }
    }

    // MARK: - Validation

    private static func validate(_ data: Data) throws -> Validated {
        guard data.count <= CodexImportSourceAuthReader.maximumBytes else {
            throw CodexManagedAccountImportError.sourceAuthTooLarge
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              Self.nonEmpty(tokens, "access_token", "accessToken") != nil,
              Self.nonEmpty(tokens, "refresh_token", "refreshToken") != nil,
              (try? CodexOAuthCredentialsStore.parse(data: data)) != nil,
              let account = try? PreparedPromotionContextBuilder.runtimeAccount(from: data)
        else { throw CodexManagedAccountImportError.sourceNotOAuth }
        guard let email = account.email, !email.isEmpty else {
            throw CodexManagedAccountImportError.sourceMissingEmail
        }
        guard case let .providerAccount(rawID) = account.identity,
              let workspaceID = ManagedCodexAccount.normalizeWorkspaceAccountID(rawID)
        else { throw CodexManagedAccountImportError.sourceMissingWorkspaceIdentity }
        return Validated(
            data: data,
            email: ManagedCodexAccount.normalizeEmail(email),
            workspaceAccountID: workspaceID,
            fingerprint: CodexAuthFingerprint.fingerprint(data: data))
    }

    private static func nonEmpty(_ dictionary: [String: Any], _ snake: String, _ camel: String) -> String? {
        for key in [snake, camel] {
            if let value = (dictionary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty
            {
                return value
            }
        }
        return nil
    }

    private func managedAuthMatches(_ account: ManagedCodexAccount, fingerprint: String) -> Bool {
        let home = URL(fileURLWithPath: account.managedHomePath, isDirectory: true)
        guard let data = try? DefaultCodexAuthMaterialReader().readAuthData(homeURL: home) else { return false }
        return CodexAuthFingerprint.fingerprint(data: data) == fingerprint
            && (account.authFingerprint == nil || account.authFingerprint == fingerprint)
    }

    // MARK: - Managed home

    private func createPrivateHome(_ homeURL: URL) throws {
        let parent = homeURL.deletingLastPathComponent()
        try self.fileManager.createDirectory(
            at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var parentStatus = stat()
        guard parent.path.withCString({ lstat($0, &parentStatus) }) == 0,
              parentStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else { throw CodexManagedAccountImportError.unsafeManagedHome }
        // Exclusive: an existing path (including a symlink) is never reused.
        guard homeURL.path.withCString({ mkdir($0, mode_t(0o700)) }) == 0,
              homeURL.path.withCString({ chmod($0, mode_t(0o700)) }) == 0
        else { throw CodexManagedAccountImportError.managedHomeWriteFailed }
    }

    private func writeAndVerify(_ source: Validated, to homeURL: URL) throws {
        let authURL = CodexAuthFingerprint.authFileURL(homePath: homeURL.path)
        try CredentialFileWriter.writePrivate(source.data, to: authURL)
        let copied = try Data(contentsOf: authURL)
        guard copied == source.data,
              CodexAuthFingerprint.fingerprint(data: copied) == source.fingerprint,
              let copiedAccount = try? PreparedPromotionContextBuilder.runtimeAccount(from: copied),
              copiedAccount.email == source.email,
              copiedAccount.identity == .providerAccount(id: source.workspaceAccountID)
        else { throw CodexManagedAccountImportError.managedHomeWriteFailed }
        var status = stat()
        guard authURL.path.withCString({ lstat($0, &status) }) == 0, status.st_mode & 0o777 == 0o600 else {
            throw CodexManagedAccountImportError.managedHomeWriteFailed
        }
    }

    private func removeHomeIfUnreferenced(_ homeURL: URL, id: UUID) {
        // If the registry cannot be read, a failed save may still have committed this home. Keep it.
        guard let accounts = try? self.store.loadAccounts(),
              !accounts.accounts.contains(where: { $0.id == id || Self.samePath($0.managedHomePath, homeURL.path) })
        else { return }
        guard (try? self.homeFactory.validateManagedHomeForDeletion(homeURL)) != nil,
              UUID(uuidString: homeURL.lastPathComponent) != nil,
              CodexCredentialFileAccess.permits(CodexAuthFingerprint.authFileURL(homePath: homeURL.path))
        else { return }
        var status = stat()
        guard homeURL.path.withCString({ lstat($0, &status) }) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else { return }
        try? self.fileManager.removeItem(at: homeURL)
        FileManagedCodexAccountStore.logHomeDeletion(mutation: .addOrReauth)
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }
}
