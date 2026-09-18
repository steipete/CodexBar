import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CodexTransportIdentityTests {
    nonisolated static let transportCodes: [URLError.Code] = [
        .timedOut, .cancelled, .networkConnectionLost, .notConnectedToInternet,
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
    ]

    enum Wrapper: CaseIterable {
        case usage
        case refresh

        func wrap(_ error: any Error) -> any Error {
            switch self {
            case .usage: CodexOAuthFetchError.networkError(error)
            case .refresh: CodexTokenRefresher.RefreshError.networkError(error)
            }
        }

        var descriptionPrefix: String {
            switch self {
            case .usage: "Network error: "
            case .refresh: "Network error during token refresh: "
            }
        }
    }

    @Test(arguments: transportCodes)
    func `localized usage transport failures retain refresh policy`(code: URLError.Code) async throws {
        let transport = ProviderHTTPTransportStub { _ in throw Self.localizedError(code: code) }
        do {
            _ = try await CodexOAuthUsageFetcher.fetchUsage(
                accessToken: "synthetic-access-token",
                accountId: "synthetic-account",
                env: ["CODEX_HOME": FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).path],
                session: transport)
            Issue.record("Expected synthetic transport failure")
        } catch {
            if code == .cancelled {
                #expect(error is CancellationError)
            } else {
                let wrapped = try #require(error as? CodexOAuthFetchError)
                guard case let .networkError(underlying) = wrapped else {
                    Issue.record("Expected wrapped transport failure")
                    return
                }
                #expect((underlying as NSError).domain == NSURLErrorDomain)
                #expect((underlying as NSError).code == code.rawValue)
                #expect(error.localizedDescription == "Network error: Verbindung fehlgeschlagen")
            }
            Self.expectPolicy(error, code: code)
        }
        #expect(await transport.requests().count == 1)
    }

    @Test(arguments: Wrapper.allCases, transportCodes)
    func `typed Codex wrappers retain localized transport classification`(wrapper: Wrapper, code: URLError.Code) {
        let error = wrapper.wrap(Self.localizedError(code: code))
        #expect(error.localizedDescription == wrapper.descriptionPrefix + "Verbindung fehlgeschlagen")
        Self.expectPolicy(error, code: code)
    }

    @Test(arguments: Wrapper.allCases)
    func `wrapped task cancellation retains cancellation policy`(wrapper: Wrapper) {
        Self.expectPolicy(wrapper.wrap(CancellationError()), code: .cancelled)
    }

    @Test(arguments: Wrapper.allCases, [URLError.Code.secureConnectionFailed, .badURL])
    func `other URL failures do not become preservable or retryable`(wrapper: Wrapper, code: URLError.Code) {
        let error = wrapper.wrap(Self.localizedError(code: code))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        #expect(UsageStore.refreshFailureHookStatus(error) == "network_error")
        #expect(error.localizedDescription == wrapper.descriptionPrefix + "Verbindung fehlgeschlagen")
    }

    @Test
    func `authentication failures keep their existing policy and descriptions`() {
        let failures: [(any Error, String)] = [
            (
                CodexOAuthFetchError.unauthorized,
                "Codex OAuth token expired or invalid. Run `codex login` to re-authenticate."),
            (
                CodexOAuthFetchError.forbidden,
                "Codex request was forbidden (HTTP 403)."),
            (
                CodexTokenRefresher.RefreshError.expired,
                "Refresh token expired. Please run `codex` to log in again."),
            (
                CodexTokenRefresher.RefreshError.revoked,
                "Refresh token was revoked. Please run `codex` to log in again."),
            (
                CodexTokenRefresher.RefreshError.reused,
                "Refresh token was already used. Please run `codex` to log in again."),
        ]
        for (error, description) in failures {
            #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
            #expect(!UsageStore.isStartupConnectivityRetryableError(error))
            #expect(UsageStore.refreshFailureHookStatus(error) == "error")
            #expect(error.localizedDescription == description)
        }
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .cancelled])
    func `arbitrary underlying NSError is not unwrapped`(code: URLError.Code) {
        let error = NSError(domain: "synthetic-provider", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Synthetic provider failure",
            NSUnderlyingErrorKey: Self.localizedError(code: code),
        ])
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.isStartupConnectivityRetryableError(error))
        #expect(UsageStore.refreshFailureHookStatus(error) == "error")
        #expect(!UsageStore.errorIsCancellation(error))
    }

    @Test
    func `provider descriptions retain the existing text fallback`() {
        let error = CodexOAuthFetchError.serverError(503, "Synthetic upstream timed out")
        #expect(UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: false))
        #expect(UsageStore.isStartupConnectivityRetryableError(error))
        #expect(UsageStore.refreshFailureHookStatus(error) == "error")
        #expect(error.localizedDescription == "Codex API error 503: Synthetic upstream timed out")
    }

    private nonisolated static func localizedError(code: URLError.Code) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "Verbindung fehlgeschlagen",
        ])
    }

    private static func expectPolicy(_ error: any Error, code: URLError.Code) {
        #expect(UsageStore.errorIsCancellation(error) == (code == .cancelled))
        #expect(UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
        #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: false))
        #expect(UsageStore.isStartupConnectivityRetryableError(error) == (code != .cancelled))
        let expectedHook = code == .timedOut ? "timeout" : code == .cancelled ? "cancelled" : "offline"
        #expect(UsageStore.refreshFailureHookStatus(error) == expectedHook)
    }
}
