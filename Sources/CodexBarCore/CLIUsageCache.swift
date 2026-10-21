#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
#if os(macOS)
import Security
import SweetCookieKit
#endif

/// Private same-user usage cache the menu bar app writes (opt-in via `CodexBarConfig.shareUsageWithCLI`). SSH sessions
/// cannot unlock the login keychain, so `codexbar usage` there can fail while the app holds fresh numbers; the CLI
/// reads this file only after a locked-keychain failure. Carries rate-window figures only: no credentials, balances,
/// or account identity.
public struct CLIUsageCache: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        /// `UsageProvider.rawValue`; a string so providers unknown to an older CLI don't break decoding.
        public let provider: String
        /// Allowlisted fields only: windows and `updatedAt` (this provider's fetch time).
        public let usage: UsageSnapshot

        /// Nil when there is no rate window to show.
        public init?(provider: UsageProvider, usage: UsageSnapshot) {
            guard usage.hasRateLimitWindows else { return nil }
            self.provider = provider.rawValue
            self.usage = Self.figures(usage)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.provider = try container.decode(String.self, forKey: .provider)
            self.usage = try Self.figures(container.decode(UsageSnapshot.self, forKey: .usage))
        }

        private static func figures(_ usage: UsageSnapshot) -> UsageSnapshot {
            UsageSnapshot(
                primary: usage.primary,
                secondary: usage.secondary,
                tertiary: usage.tertiary,
                extraRateWindows: usage.extraRateWindows,
                updatedAt: usage.updatedAt)
        }
    }

    /// An entry served to the CLI, with its age at read time.
    public struct Hit: Sendable {
        public let entry: Entry
        public let ageSeconds: Int
    }

    /// Older entries are ignored so the CLI reports its own error instead of misleading numbers.
    public static let maximumAge: TimeInterval = 3600

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("CodexBar/CLIUsageCache/usage.json", isDirectory: false)
    }

    /// Atomic write of a `0600` file inside a same-user `0700` directory (never a symlink).
    public static func write(
        _ cache: CLIUsageCache,
        to url: URL = defaultURL()) throws
    {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var attributes = stat()
        guard lstat(directory.path, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_uid == geteuid()
        else { throw CocoaError(.fileWriteNoPermission) }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try CredentialFileWriter.writePrivate(encoder.encode(cache), to: url)
    }

    /// Nil unless the file is a private regular file owned by `ownerUID` and decodes.
    public static func load(from url: URL = defaultURL(), ownerUID: uid_t = geteuid()) -> CLIUsageCache? {
        // O_NOFOLLOW + fstat vet the very file that gets read; O_NONBLOCK keeps a FIFO from hanging the open.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == ownerUID,
              metadata.st_mode & 0o7777 == 0o600,
              let data = try? handle.readToEnd()
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CLIUsageCache.self, from: data)
    }

    public func hit(for provider: UsageProvider, now: Date = Date()) -> Hit? {
        guard let entry = self.entries.first(where: { $0.provider == provider.rawValue }),
              entry.usage.hasRateLimitWindows
        else { return nil }
        let age = now.timeIntervalSince(entry.usage.updatedAt)
        guard (0...Self.maximumAge).contains(age) else { return nil }
        return Hit(entry: entry, ageSeconds: Int(age))
    }

    /// Serves cached usage after a failed fetch, only in a non-GUI session (local behavior there is unchanged), only
    /// when the fetch hit a locked keychain, and only when the terminal failure is itself a credential-access one.
    /// A lock seen by an unrelated optional lookup must not mask a timeout, parse error, or HTTP rejection.
    public static func fallbackReader(
        config: CodexBarConfig,
        url: URL = defaultURL(),
        hasGraphicSession: () -> Bool = CLIUsageCache.callerHasGraphicSession,
        now: @escaping @Sendable () -> Date = { Date() })
        -> (@Sendable (UsageProvider, _ lockedKeychainObserved: Bool, _ terminalError: Error) -> Hit?)?
    {
        guard config.shareUsageWithCLI, !hasGraphicSession() else { return nil }
        return { provider, lockedKeychainObserved, terminalError in
            guard lockedKeychainObserved, Self.isCredentialAccessFailure(terminalError) else { return nil }
            // Provider-specific by design: managed/profile Codex homes do not own the app's live-system cache.
            guard provider != .codex ||
                (config.providerConfig(for: .codex)?.codexActiveSource ?? .liveSystem) == .liveSystem
            else { return nil }
            return Self.load(from: url)?.hit(for: provider, now: now())
        }
    }

    /// True when the provider failed because it could not obtain a credential or cookie (the symptom a locked
    /// keychain produces), not because a server, parser, or timeout rejected a credential it did have.
    /// Provider-specific by design: only error types known to carry that meaning qualify; everything else keeps its
    /// own error.
    public static func isCredentialAccessFailure(_ error: Error) -> Bool {
        switch error {
        case let error as ProviderBrowserSessionFailure:
            return Self.isCredentialAccessFailure(error.underlyingError)
        case let error as ProviderFetchClassifiedError:
            // `.authenticationExpired` is the server rejecting a credential that was read fine.
            return error.kind == .missingCredential || error.kind == .permissionDenied
        case ClaudeWebAPIFetcher.FetchError.noSessionKeyFound:
            return true
        case let error as ClaudeOAuthCredentialsError:
            switch error {
            case .keychainError, .keychainAccessRevoked, .notFound, .missingOAuth, .missingAccessToken: return true
            default: return false
            }
        default:
            #if os(macOS)
            if case BrowserCookieError.accessDenied = error { return true }
            #endif
            return false
        }
    }

    #if os(macOS)
    /// Unknown session state counts as a GUI session so the existing local-only behavior stays.
    public static func callerHasGraphicSession() -> Bool {
        var attributes = SessionAttributeBits()
        guard SessionGetInfo(callerSecuritySession, nil, &attributes) == errSecSuccess else { return true }
        return attributes.contains(.sessionHasGraphicAccess)
    }

    /// Runs `body` and reports whether a Keychain read inside it failed the way a locked keychain does.
    public static func observingLockedKeychain<T>(_ body: () async -> T) async -> (T, Bool) {
        let witness = KeychainLockWitness()
        let result = await KeychainLockWitness.$current.withValue(witness) { await body() }
        return (result, witness.didObserveLockedKeychain)
    }
    #else
    public static func callerHasGraphicSession() -> Bool {
        true
    }

    public static func observingLockedKeychain<T>(_ body: () async -> T) async -> (T, Bool) {
        await (body(), false)
    }
    #endif
}
