import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct MiniMaxTransportIdentityTests {
    enum Route: CaseIterable, Sendable {
        case api
        case html
        case remains
    }

    @Test(arguments: Route.allCases)
    func `cancelled transports do not try another endpoint`(route: Route) async throws {
        let transport = ProviderHTTPTransportStub { request in
            if route == .remains, let url = request.url, url.path.contains("coding-plan") {
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"]))
                return (Data("<html>synthetic fixture</html>".utf8), response)
            }
            throw URLError(.cancelled)
        }
        do {
            if route == .api {
                _ = try await MiniMaxUsageFetcher.fetchUsage(
                    apiToken: "sk-cp-test", region: .chinaMainland, session: transport)
            } else {
                _ = try await MiniMaxUsageFetcher.fetchUsage(
                    cookieHeader: "HERTZ-SESSION=synthetic",
                    region: .chinaMainland,
                    environment: [:],
                    includeBillingHistory: false,
                    session: transport)
            }
            Issue.record("Expected cancellation")
        } catch {
            #expect((error as NSError).domain == NSURLErrorDomain)
            #expect((error as NSError).code == NSURLErrorCancelled)
        }
        #expect(await transport.requests().count == (route == .remains ? 2 : 1))
    }

    @Test(arguments: [NSURLErrorCancelled, NSURLErrorCannotFindHost, 42])
    func `official auth rejection only replaces recognized legacy transport errors`(code: Int) async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path == "/v1/token_plan/remains" {
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil))
                return (Data("{}".utf8), response)
            }
            throw NSError(domain: code == 42 ? "synthetic-error" : NSURLErrorDomain, code: code)
        }
        do {
            _ = try await MiniMaxUsageFetcher.fetchUsage(
                apiToken: "sk-cp-test", region: .chinaMainland, session: transport)
            Issue.record("Expected endpoint failure")
        } catch {
            if code == NSURLErrorCannotFindHost {
                #expect(error as? MiniMaxUsageError == .invalidCredentials)
            } else {
                #expect((error as NSError).code == code)
                #expect((error as NSError).domain == (code == 42 ? "synthetic-error" : NSURLErrorDomain))
            }
        }
        #expect(await transport.requests().count == 2)
    }

    @Test
    func `invalid server responses retain their existing diagnostic description`() async throws {
        let transport = ProviderHTTPTransportStub { _ in throw URLError(.badServerResponse) }
        do {
            _ = try await MiniMaxUsageFetcher.fetchUsage(
                apiToken: "sk-cp-test", region: .chinaMainland, session: transport)
            Issue.record("Expected invalid response")
        } catch {
            #expect((error as NSError).domain == NSURLErrorDomain)
            #expect((error as NSError).code == NSURLErrorBadServerResponse)
            #expect(error.localizedDescription == "MiniMax network error: Invalid response")
            #expect(ProviderDiagnosticError(from: error, authConfigured: true).category == "network")
        }
    }

    @Test(arguments: [
        URLError.Code.cannotFindHost, .cannotConnectToHost, .notConnectedToInternet,
        .timedOut, .dnsLookupFailed, .networkConnectionLost,
    ], Route.allCases)
    func `translated transport failures keep machine identity and cached usage policy`(
        code: URLError.Code,
        route: Route) async throws
    {
        let transport = ProviderHTTPTransportStub { request in
            if route == .remains, let url = request.url, url.path.contains("coding-plan") {
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]))
                return (Data("<html>synthetic fixture</html>".utf8), response)
            }
            throw NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: [
                NSLocalizedDescriptionKey: "Verbindung fehlgeschlagen",
                "synthetic-marker": "preserved",
            ])
        }
        do {
            if route == .api {
                _ = try await MiniMaxUsageFetcher.fetchUsage(
                    apiToken: "sk-cp-test",
                    region: .chinaMainland,
                    session: transport)
            } else {
                _ = try await MiniMaxUsageFetcher.fetchUsage(
                    cookieHeader: "HERTZ-SESSION=synthetic",
                    region: .chinaMainland,
                    environment: [:],
                    includeBillingHistory: false,
                    session: transport)
            }
            Issue.record("Expected a synthetic transport failure")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == NSURLErrorDomain)
            #expect(failure.code == code.rawValue)
            #expect(failure.userInfo["synthetic-marker"] as? String == "preserved")
            #expect(error.localizedDescription == "MiniMax network error: Verbindung fehlgeschlagen")
            #expect(UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
            #expect(!UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: false))
            #expect(UsageStore.isStartupConnectivityRetryableError(error))
            #expect(UsageStore.refreshFailureHookStatus(error) == (code == .timedOut ? "timeout" : "offline"))
            #expect(ProviderDiagnosticError(from: error, authConfigured: true).category == "network")
            #expect(ProviderDiagnosticFetchAttempt.errorCategoryLabel(error.localizedDescription) == "network")
        }
        let requests = await transport.requests()
        #expect(requests.count == (route == .api ? 2 : route == .html ? 1 : 3))
    }
}
