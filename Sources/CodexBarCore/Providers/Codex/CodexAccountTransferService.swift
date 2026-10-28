import Crypto
import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

package struct CodexAccountTransferFailure: Equatable, Sendable {
    package let email: String
    package let message: String

    package init(email: String, message: String) {
        self.email = email
        self.message = message
    }
}

/// Safe per-import summary. It never carries credentials, fingerprints, ids, or paths.
package struct CodexAccountTransferReport: Equatable, Sendable {
    package let importedCount: Int
    package let existingCount: Int
    package let failures: [CodexAccountTransferFailure]

    package init(importedCount: Int, existingCount: Int, failures: [CodexAccountTransferFailure]) {
        self.importedCount = importedCount
        self.existingCount = existingCount
        self.failures = failures
    }
}

package enum CodexAccountTransferError: Error, Equatable, LocalizedError {
    case unsupportedPlatform
    case passwordTooShort
    case noAccounts
    case tooManyAccounts
    case accountUnreadable(email: String)
    case accountNotPortable(email: String)
    case packageTooLarge
    case invalidPackage
    case unsupportedVersion
    case unsupportedIterations
    case invalidSalt
    case decryptionFailed

    package var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: "Encrypted account transfer is only available on macOS."
        case .passwordTooShort:
            "Use a password of at least \(CodexAccountTransferService.minimumPasswordLength) characters."
        case .noAccounts: "There are no managed Codex accounts to export."
        case .tooManyAccounts:
            "A transfer package holds at most \(CodexAccountTransferService.maximumAccounts) accounts."
        case let .accountUnreadable(email): "Credentials for \(email) are missing or unreadable. Nothing was exported."
        case let .accountNotPortable(email):
            "\(email) cannot be exported safely: its credentials are not usable OAuth tokens, or its saved "
                + "email or workspace differs from its credentials. Nothing was exported."
        case .packageTooLarge: "The account transfer data exceeds the size limit."
        case .invalidPackage: "This is not a valid CodexBar account transfer package."
        case .unsupportedVersion: "This account transfer package version is not supported."
        case .unsupportedIterations: "This account transfer package uses unsupported key derivation settings."
        case .invalidSalt: "This account transfer package is malformed."
        case .decryptionFailed: "Could not decrypt the account transfer package. Check the password and the file."
        }
    }
}

/// Encrypted export/import of managed Codex accounts.
///
/// Export reads each managed home under the registry lock and seals a portable payload
/// (email, workspace id, workspace label, auth JSON) with a password. Import decrypts and validates the
/// whole payload in memory before any registry write, then imports each account independently through
/// `CodexManagedAccountImportTransaction` into fresh managed homes. It never promotes an account, selects an
/// active account, writes config or environment, or touches the Keychain or network.
package struct CodexAccountTransferService: Sendable {
    package static let minimumPasswordLength = 12
    package static let maximumAccounts = 50
    package static let maximumPackageBytes = 8 * 1024 * 1024
    package static let formatVersion = 1
    package static let iterations = 600_000
    package static let saltLength = 16

    private static let keyLength = 32
    private static let nonceAndTagOverhead = 12 + 16
    private static let memorySourceHome = URL(fileURLWithPath: "/codexbar-account-transfer", isDirectory: true)

    private let store: any ManagedCodexAccountStoring
    private let homeFactory: any ManagedCodexHomeProducing

    package init(store: any ManagedCodexAccountStoring, homeFactory: any ManagedCodexHomeProducing) {
        self.store = store
        self.homeFactory = homeFactory
    }

    // MARK: - Export

    package func exportAccounts(password: String) throws -> Data {
        try Self.requireSupportedPlatform()
        guard password.count >= Self.minimumPasswordLength else { throw CodexAccountTransferError.passwordTooShort }
        let entries = try ManagedCodexAccountLock.withLock(at: self.store.lockURL) {
            try self.collectEntries()
        }
        let plaintext = try Self.encodePayload(Payload(accounts: entries))
        return try Self.seal(plaintext: plaintext, password: password)
    }

    private func collectEntries() throws -> [Entry] {
        let accounts = try self.store.loadAccounts().accounts
        guard !accounts.isEmpty else { throw CodexAccountTransferError.noAccounts }
        guard accounts.count <= Self.maximumAccounts else { throw CodexAccountTransferError.tooManyAccounts }
        let reader = CodexImportSourceAuthReader()
        return try accounts.map { account in
            let home = URL(fileURLWithPath: account.managedHomePath, isDirectory: true)
            guard let data = try? reader.readAuthData(homeURL: home), let authJSON = String(data: data, encoding: .utf8)
            else { throw CodexAccountTransferError.accountUnreadable(email: account.email) }
            guard let identity = Self.inspect(data),
                  identity.email == account.email,
                  // The importer always records the credential's own workspace. A saved selection that differs
                  // from the auth default cannot be reproduced, so refuse rather than substitute silently.
                  identity.workspaceAccountID == account.effectiveWorkspaceAccountID
            else { throw CodexAccountTransferError.accountNotPortable(email: account.email) }
            return Entry(
                email: account.email,
                workspaceAccountID: identity.workspaceAccountID,
                workspaceLabel: account.workspaceLabel,
                authJSON: authJSON)
        }
    }

    // MARK: - Import

    package func importAccounts(data: Data, password: String) throws -> CodexAccountTransferReport {
        try Self.requireSupportedPlatform()
        let plaintext = try Self.open(envelopeData: data, password: password)
        let entries = try Self.validatedEntries(from: plaintext)

        var imported = 0
        var existing = 0
        var failures: [CodexAccountTransferFailure] = []
        for entry in entries {
            do {
                let transaction = CodexManagedAccountImportTransaction(
                    store: self.store,
                    homeFactory: self.homeFactory,
                    authMaterialReader: InMemoryAuthReader(data: Data(entry.authJSON.utf8)))
                let receipt = try transaction.importProfile(
                    fromHome: Self.memorySourceHome,
                    workspaceLabel: entry.workspaceLabel)
                switch receipt.outcome {
                case .imported: imported += 1
                case .existing: existing += 1
                }
            } catch let error as CodexManagedAccountImportError {
                failures.append(CodexAccountTransferFailure(
                    email: entry.email, message: error.localizedDescription))
            } catch {
                failures.append(CodexAccountTransferFailure(
                    email: entry.email, message: "Could not import this account."))
            }
        }
        return CodexAccountTransferReport(importedCount: imported, existingCount: existing, failures: failures)
    }

    /// Whole-package validation: every entry must be self-consistent before any registry write.
    private static func validatedEntries(from plaintext: Data) throws -> [Entry] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: plaintext) else {
            throw CodexAccountTransferError.invalidPackage
        }
        guard !payload.accounts.isEmpty else { throw CodexAccountTransferError.invalidPackage }
        guard payload.accounts.count <= self.maximumAccounts else { throw CodexAccountTransferError.tooManyAccounts }
        return try payload.accounts.map { entry in
            let bytes = Data(entry.authJSON.utf8)
            guard bytes.count <= CodexImportSourceAuthReader.maximumBytes else {
                throw CodexAccountTransferError.packageTooLarge
            }
            guard let identity = self.inspect(bytes),
                  identity.email == ManagedCodexAccount.normalizeEmail(entry.email),
                  identity.workspaceAccountID == ManagedCodexAccount.normalizeWorkspaceAccountID(
                      entry.workspaceAccountID)
            else { throw CodexAccountTransferError.invalidPackage }
            return Entry(
                email: identity.email,
                workspaceAccountID: identity.workspaceAccountID,
                workspaceLabel: ManagedCodexAccount.normalizeWorkspaceLabel(entry.workspaceLabel),
                authJSON: entry.authJSON)
        }
    }

    // MARK: - Payload

    struct Entry: Codable, Equatable {
        let email: String
        let workspaceAccountID: String
        let workspaceLabel: String?
        let authJSON: String
    }

    struct Payload: Codable {
        let accounts: [Entry]
    }

    static func encodePayload(_ payload: Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard data.count <= self.maximumPackageBytes - self.nonceAndTagOverhead else {
            throw CodexAccountTransferError.packageTooLarge
        }
        return data
    }

    private static func inspect(_ data: Data) -> (email: String, workspaceAccountID: String)? {
        guard data.count <= CodexImportSourceAuthReader.maximumBytes,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              self.nonEmpty(tokens, "access_token", "accessToken"),
              self.nonEmpty(tokens, "refresh_token", "refreshToken"),
              let account = try? PreparedPromotionContextBuilder.runtimeAccount(from: data),
              let email = account.email, !email.isEmpty,
              case let .providerAccount(rawID) = account.identity,
              let workspace = ManagedCodexAccount.normalizeWorkspaceAccountID(rawID)
        else { return nil }
        return (ManagedCodexAccount.normalizeEmail(email), workspace)
    }

    private static func nonEmpty(_ dictionary: [String: Any], _ snake: String, _ camel: String) -> Bool {
        [snake, camel].contains { key in
            ((dictionary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
    }

    // MARK: - Envelope

    private struct Envelope: Codable {
        let version: Int
        let iterations: Int
        let salt: String
        let sealed: String
    }

    /// Fixed canonical header authenticated as AES-GCM additional data.
    private static func additionalData(version: Int, iterations: Int, salt: Data) -> Data {
        var data = Data("CodexBar.CodexAccountTransfer".utf8)
        data.append(0)
        for value in [UInt32(version), UInt32(iterations)] {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        data.append(salt)
        return data
    }

    static func seal(plaintext: Data, password: String) throws -> Data {
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<self.saltLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return try self.seal(plaintext: plaintext, password: password, salt: salt)
    }

    static func seal(plaintext: Data, password: String, salt: Data) throws -> Data {
        try self.requireSupportedPlatform()
        guard salt.count == self.saltLength else { throw CodexAccountTransferError.invalidSalt }
        guard plaintext.count <= self.maximumPackageBytes - self.nonceAndTagOverhead else {
            throw CodexAccountTransferError.packageTooLarge
        }
        let key = try self.deriveKey(password: password, salt: salt, iterations: self.iterations)
        let aad = self.additionalData(version: self.formatVersion, iterations: self.iterations, salt: salt)
        guard let combined = try? AES.GCM.seal(plaintext, using: key, authenticating: aad).combined else {
            throw CodexAccountTransferError.invalidPackage
        }
        let envelope = Envelope(
            version: self.formatVersion,
            iterations: self.iterations,
            salt: salt.base64EncodedString(),
            sealed: combined.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let output = try encoder.encode(envelope)
        guard output.count <= self.maximumPackageBytes else { throw CodexAccountTransferError.packageTooLarge }
        return output
    }

    /// Validates every header field and size before the expensive key derivation or any allocation of the
    /// decoded ciphertext.
    static func open(envelopeData: Data, password: String) throws -> Data {
        try self.requireSupportedPlatform()
        guard envelopeData.count <= self.maximumPackageBytes else { throw CodexAccountTransferError.packageTooLarge }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: envelopeData) else {
            throw CodexAccountTransferError.invalidPackage
        }
        guard envelope.version == self.formatVersion else { throw CodexAccountTransferError.unsupportedVersion }
        guard envelope.iterations == self.iterations else { throw CodexAccountTransferError.unsupportedIterations }
        // Base64 expands 3 bytes to 4; compare encoded lengths so nothing oversized is ever decoded.
        guard envelope.salt.utf8.count == (self.saltLength + 2) / 3 * 4,
              let salt = Data(base64Encoded: envelope.salt), salt.count == self.saltLength
        else { throw CodexAccountTransferError.invalidSalt }
        guard envelope.sealed.utf8.count <= (self.maximumPackageBytes + 2) / 3 * 4 else {
            throw CodexAccountTransferError.packageTooLarge
        }
        guard let combined = Data(base64Encoded: envelope.sealed),
              combined.count > self.nonceAndTagOverhead,
              combined.count <= self.maximumPackageBytes
        else { throw CodexAccountTransferError.invalidPackage }

        let key = try self.deriveKey(password: password, salt: salt, iterations: envelope.iterations)
        let aad = self.additionalData(version: envelope.version, iterations: envelope.iterations, salt: salt)
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plaintext = try? AES.GCM.open(box, using: key, authenticating: aad)
        else { throw CodexAccountTransferError.decryptionFailed }
        return plaintext
    }

    private static func requireSupportedPlatform() throws {
        #if !canImport(CommonCrypto)
        throw CodexAccountTransferError.unsupportedPlatform
        #endif
    }

    #if canImport(CommonCrypto)
    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: self.keyLength)
        let passwordBytes = Array(password.utf8)
        let status = passwordBytes.withUnsafeBufferPointer { passwordPointer in
            salt.withUnsafeBytes { saltPointer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPointer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) },
                    passwordBytes.count,
                    saltPointer.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived,
                    derived.count)
            }
        }
        guard status == kCCSuccess else { throw CodexAccountTransferError.decryptionFailed }
        defer { for index in derived.indices {
            derived[index] = 0
        } }
        return SymmetricKey(data: derived)
    }
    #else
    private static func deriveKey(password _: String, salt _: Data, iterations _: Int) throws -> SymmetricKey {
        throw CodexAccountTransferError.unsupportedPlatform
    }
    #endif
}

/// Serves decrypted credential bytes from memory so the plaintext never touches disk before the importer
/// writes the private managed copy.
private struct InMemoryAuthReader: CodexAuthMaterialReading {
    let data: Data
    func readAuthData(homeURL _: URL) throws -> Data? { self.data }
}
