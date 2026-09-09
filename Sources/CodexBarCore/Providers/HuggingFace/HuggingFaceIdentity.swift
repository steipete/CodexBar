import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Result of an authenticated `whoami-v2` probe.
///
/// `opaqueUserID` is the matching-layer correlation key from FP-193/FP-194. It must stay transient:
/// never persist it into snapshots or history, never log it, and never display it. Only the display
/// fields are projected into `ProviderIdentitySnapshot`.
public struct HuggingFaceIdentity: Equatable, Sendable {
    public let opaqueUserID: String
    public let accountID: String?
    public let email: String?
    public let isPro: Bool

    /// Display-only projection for `UsageSnapshot.identity`. Drops the opaque matching ID and
    /// mirrors the display mapping the former plugin-owned identity provided.
    public func displayIdentitySnapshot(provider: UsageProvider) -> ProviderIdentitySnapshot? {
        guard self.accountID != nil || self.email != nil || self.isPro else { return nil }
        return ProviderIdentitySnapshot(
            providerID: provider.instanceID,
            accountEmail: self.email,
            accountOrganization: nil,
            loginMethod: self.isPro ? "PRO" : nil,
            accountID: self.accountID)
    }
}

/// Provider-private owner of `GET https://huggingface.co/api/whoami-v2`.
///
/// Successful identities are cached in memory for 12 hours keyed by a one-way credential
/// fingerprint (`CookieHeaderCache.credentialFingerprint`), never by the raw token or cookie
/// header. Identical in-flight lookups are coalesced by the same fingerprint key, so concurrent
/// callers race one shared `whoami-v2` request per cache miss instead of one request each.
/// Failures are not cached so a transient identity outage retries on the next refresh.
/// Cancellation always propagates: a cancelled waiter rethrows `CancellationError` after the
/// shared operation settles, without duplicating requests or discarding the shared success for
/// other callers. Every non-cancellation failure resolves to `nil` ("identity unavailable")
/// because billing never depends on identity.
public actor HuggingFaceIdentityService {
    static let cacheTTLSeconds: TimeInterval = 12 * 60 * 60

    public static let shared = HuggingFaceIdentityService()

    struct CacheEntry: Sendable {
        let identity: HuggingFaceIdentity
        let expiresAt: Date
    }

    private let transport: any ProviderHTTPTransport
    var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: HuggingFaceSingleFlight<HuggingFaceIdentity?>] = [:]

    public init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
    }

    public static let whoamiURL = URL(string: "https://huggingface.co/api/whoami-v2")!

    public func identity(
        bearerToken: String,
        timeout: TimeInterval) async throws -> HuggingFaceIdentity?
    {
        try await self.identity(
            cacheKeyPrefix: "bearer:",
            credential: bearerToken,
            headerField: "Authorization",
            headerValue: "Bearer \(bearerToken)",
            timeout: timeout)
    }

    public func identity(
        cookieHeader: String,
        timeout: TimeInterval) async throws -> HuggingFaceIdentity?
    {
        try await self.identity(
            cacheKeyPrefix: "cookie:",
            credential: cookieHeader,
            headerField: "Cookie",
            headerValue: cookieHeader,
            timeout: timeout)
    }

    private func identity(
        cacheKeyPrefix: String,
        credential: String,
        headerField: String,
        headerValue: String,
        timeout: TimeInterval) async throws -> HuggingFaceIdentity?
    {
        let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCredential.isEmpty else { return nil }
        let cacheKey = cacheKeyPrefix + CookieHeaderCache.credentialFingerprint(trimmedCredential)
        if let entry = self.cache[cacheKey], entry.expiresAt > Date() {
            return entry.identity
        }

        // Coalesce identical in-flight lookups by the fingerprint key: concurrent callers join
        // one shared `whoami-v2` operation instead of racing duplicate requests.
        let operation: HuggingFaceSingleFlight<HuggingFaceIdentity?>
        if let inFlight = self.inFlight[cacheKey] {
            operation = inFlight
        } else {
            operation = HuggingFaceSingleFlight(task: Task.detached(priority: .userInitiated) {
                try await self.requestIdentity(
                    headerField: headerField,
                    headerValue: headerValue,
                    timeout: timeout)
            })
            self.inFlight[cacheKey] = operation
        }

        let outcome: Result<HuggingFaceIdentity?, any Error>
        do {
            outcome = try await .success(operation.task.value)
        } catch {
            outcome = .failure(error)
        }
        self.finish(cacheKey: cacheKey, operation: operation, outcome: outcome)
        // A cancelled waiter follows the caller's cancellation contract: the shared outcome is
        // still recorded above, but this caller propagates cancellation instead of consuming it.
        if Task.isCancelled {
            throw CancellationError()
        }
        do {
            return try outcome.get()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Identity lookup never blocks billing: ordinary HTTP/auth/parse/network failures
            // resolve to "identity unavailable".
            return nil
        }
    }

    /// Records the shared operation's outcome exactly once per generation. Success caches the
    /// identity for the TTL; failures only clear the in-flight entry so a later lookup is a
    /// fresh miss. The generation check keeps a slow waiter from clearing a newer operation.
    private func finish(
        cacheKey: String,
        operation: HuggingFaceSingleFlight<HuggingFaceIdentity?>,
        outcome: Result<HuggingFaceIdentity?, any Error>)
    {
        guard self.inFlight[cacheKey] === operation else { return }
        self.inFlight[cacheKey] = nil
        guard case let .success(identity) = outcome, let identity else { return }
        self.cache[cacheKey] = CacheEntry(
            identity: identity,
            expiresAt: Date().addingTimeInterval(Self.cacheTTLSeconds))
    }

    private func requestIdentity(
        headerField: String,
        headerValue: String,
        timeout: TimeInterval) async throws -> HuggingFaceIdentity?
    {
        var request = URLRequest(url: Self.whoamiURL)
        request.httpMethod = "GET"
        request.timeoutInterval = max(0.1, timeout)
        request.setValue(headerValue, forHTTPHeaderField: headerField)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await self.transport.response(for: request)
        guard response.statusCode == 200 else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: response.data),
              let payload = object as? [String: Any]
        else { return nil }
        return Self.parseIdentity(payload)
    }

    static func parseIdentity(_ payload: [String: Any]) -> HuggingFaceIdentity? {
        guard payload["type"] as? String == "user" else { return nil }
        guard let opaqueUserID = nonEmptyString(payload["id"]) else { return nil }
        let accountID = Self.nonEmptyString(payload["name"])
        let email = Self.nonEmptyString(payload["email"])
        let isPro = payload["isPro"] as? Bool == true
        return HuggingFaceIdentity(
            opaqueUserID: opaqueUserID,
            accountID: accountID,
            email: email,
            isPro: isPro)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
