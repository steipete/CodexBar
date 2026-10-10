import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Keeps Desktop provenance until dispatch. Other credential sources retain their existing behavior.
struct KimiWebCredential: Sendable {
    let token: String
    private let desktopCheck: KimiDesktopDispatchValidation?

    init(token: String) {
        self.token = token
        self.desktopCheck = nil
    }

    init(desktopToken: String, isCurrent: @escaping @Sendable () -> Bool) {
        self.token = desktopToken
        self.desktopCheck = KimiDesktopDispatchValidation(isCurrent: isCurrent)
    }

    func transport(_ base: any ProviderHTTPTransport, region: KimiRegion) -> any ProviderHTTPTransport {
        guard let desktopCheck else { return base }
        return KimiDesktopRequestTransport(base: base, token: self.token, region: region, validation: desktopCheck)
    }
}

/// Distinct from server invalidToken: do not rediscover/fallback after an observed Desktop lifecycle change.
struct KimiDesktopSessionChanged: LocalizedError {
    var errorDescription: String? {
        "Kimi Desktop session changed before the request was sent. " +
            "Confirm the intended account is signed in to Kimi Desktop, then refresh CodexBar."
    }
}

private struct KimiDesktopRequestTransport: ProviderHTTPTransport {
    let base: any ProviderHTTPTransport
    let token: String
    let region: KimiRegion
    let validation: KimiDesktopDispatchValidation

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        guard self.region == .china,
              request.url?.scheme == "https", request.url?.host == self.region.webBaseURL.host,
              request.url?.port == nil || request.url?.port == 443,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer \(self.token)",
              request.value(forHTTPHeaderField: "Cookie") == "kimi-auth=\(self.token)",
              self.validation.check() else { throw KimiDesktopSessionChanged() }
        // This narrows the observation-to-dispatch interval; it cannot revoke an already sent request.
        try Task.checkCancellation()
        return try await self.base.data(for: request)
    }
}

/// Concurrent requests share invalidation: an observed failure cannot be revived by a later identical value.
private final class KimiDesktopDispatchValidation: Sendable {
    private let valid = Mutex(true)
    private let isCurrent: @Sendable () -> Bool

    init(isCurrent: @escaping @Sendable () -> Bool) { self.isCurrent = isCurrent }

    func check() -> Bool {
        self.valid.withLock { valid in
            guard valid else { return false }
            valid = self.isCurrent()
            return valid
        }
    }
}
