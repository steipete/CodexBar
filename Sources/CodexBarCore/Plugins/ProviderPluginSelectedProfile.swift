import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Live-only ownership. Neither cookie values nor the digest are serialized or exposed to scripts.
public struct ProviderBrowserSessionOwner: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let profile: ProviderBrowserProfile
    let digest: String

    public var description: String {
        "<live browser session>"
    }

    public var debugDescription: String {
        self.description
    }

    init(
        provider: UsageProvider,
        profile: ProviderBrowserProfile,
        records: [ProviderPluginCookieRecord],
        policy: ProviderPluginCookiePolicy) throws
    {
        guard let url = policy.sessionURL else { throw ProviderPluginError.secretAccess("missing session URL") }
        let relevant = records.filter { policy.requiredCookies.contains($0.name) && $0.matches(url, now: Date()) }
        guard policy.requiredCookies.allSatisfy({ name in
            let values = Set(relevant.filter { $0.name == name }.map(\.value))
            return values.count == 1 && values.first?.isEmpty == false
        }) else {
            throw ProviderFetchClassifiedError(
                kind: .authenticationExpired,
                message: "No unambiguous session was found in the selected browser profile.")
        }
        let identities = relevant
            .map { [$0.name, $0.domain, $0.path, String($0.hostOnly), String($0.secure), $0.value] }
            .sorted { $0.lexicographicallyPrecedes($1) }
        let data = try JSONEncoder().encode([[provider.rawValue, profile.browserID, profile.profileID]] + identities)
        self.profile = profile
        self.digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ProviderBrowserSessionFailure: LocalizedError, Sendable, CustomDebugStringConvertible {
    public let owner: ProviderBrowserSessionOwner?
    public let underlyingError: Error

    public var errorDescription: String? {
        self.underlyingError.localizedDescription
    }

    public var debugDescription: String {
        self.underlyingError.localizedDescription
    }
}

/// The broker serializes this fetch-local state. Only the selected profile is read, including on failure.
final class ProviderPluginSelectedProfile {
    typealias Reader = @Sendable (ProviderBrowserProfile) throws -> [ProviderPluginCookieRecord]
    private let provider: UsageProvider
    private let profile: ProviderBrowserProfile?
    private let policy: ProviderPluginCookiePolicy
    private let read: @Sendable (Bool) throws -> [ProviderPluginCookieRecord]
    private var requestedOwner: ProviderBrowserSessionOwner?
    private var importFailure: Error?
    private var issued = false

    init(
        provider: UsageProvider,
        profile: ProviderBrowserProfile?,
        policy: ProviderPluginCookiePolicy,
        domains: Set<String>,
        reader: Reader? = nil)
    {
        self.provider = provider
        self.profile = profile
        self.policy = policy
        let operation: @Sendable (Bool) throws -> [ProviderPluginCookieRecord] = { revalidating in
            guard let profile, !profile.profileID.isEmpty else {
                throw ProviderFetchClassifiedError(
                    kind: .missingCredential, message: "Select a Browser profile in provider settings.")
            }
            let read = { try reader?(profile) ?? ProviderBrowserProfile.read(profile, domains: domains) }
            return try revalidating
                ? ProviderInteractionContext.$current.withValue(.background, operation: read) : read()
        }
        #if os(macOS)
        self.read = BrowserCookieAccessGate.operationPreservingAccessContext(operation)
        #else
        self.read = operation
        #endif
    }

    func next(domain: String, cachedOnly: Bool) throws -> ProviderPluginCookieSession? {
        guard !cachedOnly, !self.issued else { return nil }
        self.issued = true
        guard self.policy.requestHosts.contains(domain) else {
            throw ProviderPluginError.secretAccess("selected profile session origin is not declared")
        }
        do {
            let records = try self.read(false)
            self.requestedOwner = try self.owner(records)
            return ProviderPluginCookieSession(
                header: "",
                source: "Selected browser profile",
                origin: "https://\(domain)",
                records: records)
        } catch {
            // Preserve native permission classification even when a bridge converts the thrown error to text.
            self.importFailure = error
            throw error
        }
    }

    func finish(_ result: Result<ProviderPluginResult, Error>) throws -> ProviderPluginResult {
        var verified: ProviderBrowserSessionOwner?
        do {
            guard let requestedOwner else {
                if let importFailure { throw importFailure }
                if case let .failure(error) = result { throw error }
                throw ProviderPluginError.secretAccess("selected browser session was not used")
            }
            let current = try self.owner(self.read(true))
            guard current == requestedOwner else {
                throw ProviderFetchClassifiedError(
                    kind: .authenticationExpired, message: "The selected browser session changed. Refresh again.")
            }
            verified = current
            try Task.checkCancellation()
            let result = try result.get()
            guard result.persist.isEmpty else {
                throw ProviderPluginError.invalidSnapshot("selected profile results cannot persist settings")
            }
            return ProviderPluginResult(
                usage: result.usage.replacing(browserSessionOwner: .value(current)),
                sourceLabel: result.sourceLabel,
                persist: [:])
        } catch {
            throw ProviderBrowserSessionFailure(owner: verified, underlyingError: error)
        }
    }

    private func owner(_ records: [ProviderPluginCookieRecord]) throws -> ProviderBrowserSessionOwner {
        guard let profile else { throw ProviderPluginError.secretAccess("missing browser profile") }
        return try ProviderBrowserSessionOwner(
            provider: self.provider,
            profile: profile,
            records: records,
            policy: self.policy)
    }
}

extension ProviderPluginRuntime {
    func fetchResult(
        cookies: ProviderPluginCookieBroker,
        settings: [String: String] = [:],
        secrets: [String: String] = [:],
        now: Date = Date(),
        sourceMode: ProviderSourceMode = .web,
        localStorageResolver: LocalStorageResolver? = nil) async throws
        -> ProviderPluginResult
    {
        let result: Result<ProviderPluginResult, Error>
        do {
            result = try await .success(self.fetchResult(
                settings: settings,
                secrets: secrets,
                now: now,
                sourceMode: sourceMode,
                cookieSource: cookies.cookieSource,
                cookieInvalidator: { cookies.rejectCookie(domain: $0) },
                cookieSessionResolver: { try cookies.nextSession(domain: $0, cachedOnly: $1) },
                cookieSessionInvalidator: { cookies.rejectCookie(domain: $0, id: $1) },
                cookieSessionValidator: { try cookies.acceptCookie(domain: $0, id: $1) },
                cookieResolver: { _, domain in try cookies.cookieHeader(domain: domain) },
                localStorageResolver: localStorageResolver))
        } catch {
            result = .failure(error)
        }
        return try cookies.finish(result)
    }
}
