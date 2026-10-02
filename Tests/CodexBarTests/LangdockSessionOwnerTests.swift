import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore
#if os(macOS)
import os.lock

struct LangdockSessionOwnerTests {
    private static let profile = "/synthetic/Edge/Default"
    private static let headerA = "auth_token=synthetic-account-a"
    private static let headerB = "auth_token=synthetic-account-b"
    private static let response = Data("""
    [{"result":{"data":{"json":{"planUsage":{
      "sessionUsageLimitsEnabled":false,"weeklyUsagePercent":42
    }}}}}]
    """.utf8)

    private static func snapshot() throws -> UsageSnapshot {
        let owner = try #require(LangdockSessionOwner(profileID: Self.profile, cookieHeader: Self.headerA))
        return try LangdockUsageParser.parse(Self.response, statusCode: 200)
            .withLangdockSessionOwner(owner).withIdentity(ProviderIdentitySnapshot(
                providerID: .langdock,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Edge profile",
                accountID: Self.profile))
    }

    @Test
    func `session ownership binds the exact profile and auth token`() throws {
        let owner = try #require(LangdockSessionOwner(profileID: Self.profile, cookieHeader: Self.headerA))
        #expect(owner == LangdockSessionOwner(
            profileID: Self.profile, cookieHeader: "pref=changed; \(Self.headerA)"))
        #expect(owner != LangdockSessionOwner(profileID: Self.profile, cookieHeader: Self.headerB))
        #expect(owner != LangdockSessionOwner(profileID: "/synthetic/Edge/Profile 2", cookieHeader: Self.headerA))
        #expect(LangdockSessionOwner(profileID: Self.profile, cookieHeader: "pref=only") == nil)
        #expect(LangdockSessionOwner(profileID: Self.profile, cookieHeader: "\(Self.headerA); \(Self.headerB)") == nil)
    }

    @Test
    func `live copies retain ownership but encoded snapshots contain no session proof`() throws {
        let snapshot = try Self.snapshot()
        let owner = try #require(snapshot.langdockSessionOwner)
        for copy in [
            snapshot.with(details: []),
            snapshot.with(primary: nil, secondary: snapshot.secondary),
            snapshot.withIdentity(snapshot.identity),
            snapshot.withDataConfidence(.percentOnly),
            snapshot.scoped(to: .langdock),
        ] {
            #expect(copy.langdockSessionOwner == owner)
        }
        let encoded = try JSONEncoder().encode(snapshot)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains("langdockSessionOwner"))
        #expect(!text.contains(owner.tokenDigest))
        #expect(!text.contains("synthetic-account-a"))
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["langdockSessionOwner"] = ["profileID": Self.profile, "tokenDigest": owner.tokenDigest]
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.langdockSessionOwner == nil)
    }

    @Test
    func `successful responses revalidate the selected session without user interaction`() async throws {
        let interactions = OSAllocatedUnfairLock(initialState: [ProviderInteraction]())
        let transport = ProviderHTTPTransportHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Self.response, response)
        }
        let snapshot = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
            try await LangdockUsageFetcher.fetch(
                edgeProfileID: Self.profile,
                timeout: 5,
                transport: transport,
                cookieHeaderProvider: { profile in
                    #expect(profile == Self.profile)
                    interactions.withLock { $0.append(ProviderInteractionContext.current) }
                    return Self.headerA
                })
        }
        #expect(snapshot.langdockSessionOwner == LangdockSessionOwner(
            profileID: Self.profile, cookieHeader: Self.headerA))
        #expect(interactions.withLock { $0 } == [.userInitiated, .background])
    }

    @Test(arguments: ["success", "http", "network", "cancelled"])
    func `a session change during a request discards both successful and failed old results`(
        result: String) async throws
    {
        let header = OSAllocatedUnfairLock(initialState: Self.headerA)
        let transport = ProviderHTTPTransportHandler { request in
            header.withLock { $0 = Self.headerB }
            if result == "network" { throw URLError(.timedOut) }
            if result == "cancelled" { throw URLError(.cancelled) }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: result == "http" ? 503 : 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Self.response, response)
        }
        let error = await #expect(throws: LangdockFetchError.self) {
            try await LangdockUsageFetcher.fetch(
                edgeProfileID: Self.profile,
                timeout: 5,
                transport: transport,
                cookieHeaderProvider: { _ in header.withLock { $0 } })
        }
        let failure = try #require(error)
        #expect(failure.underlyingError as? LangdockUsageError == .sessionChanged)
        #expect(try !UsageStore.shouldPreservePriorSnapshot(
            after: failure, hadPriorData: true, priorSnapshot: Self.snapshot()))
        #expect(try !UsageStore.shouldSuppressProviderCancellation(failure, priorSnapshot: Self.snapshot()))
    }

    @Test(arguments: ["http", "network", "cancelled"], [false, true])
    func `transient errors preserve only the session that supplied the previous values`(
        result: String, changed: Bool) async throws
    {
        let transport = ProviderHTTPTransportHandler { request in
            if result == "network" { throw URLError(.timedOut) }
            if result == "cancelled" { throw URLError(.cancelled) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (Self.response, response)
        }
        let error = await #expect(throws: LangdockFetchError.self) {
            try await LangdockUsageFetcher.fetch(
                edgeProfileID: Self.profile,
                timeout: 5,
                transport: transport,
                cookieHeaderProvider: { _ in changed ? Self.headerB : Self.headerA })
        }
        let failure = try #require(error)
        #expect(try UsageStore.shouldPreservePriorSnapshot(
            after: failure, hadPriorData: true, priorSnapshot: Self.snapshot()) == !changed)
        #expect(try UsageStore.shouldSuppressProviderCancellation(
            failure, priorSnapshot: Self.snapshot()) == (result == "cancelled" && !changed))
    }

    @Test(arguments: [false, true])
    func `failed initial import or failed revalidation cannot retain an unverified session`(
        failRevalidation: Bool) async throws
    {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let transport = ProviderHTTPTransportHandler { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Self.response, response)
        }
        let error = await #expect(throws: LangdockFetchError.self) {
            try await LangdockUsageFetcher.fetch(
                edgeProfileID: Self.profile,
                timeout: 5,
                transport: transport,
                cookieHeaderProvider: { _ in
                    let read = reads.withLock { $0 += 1; return $0 }
                    if failRevalidation, read == 1 { return Self.headerA }
                    throw URLError(.timedOut)
                })
        }
        let failure = try #require(error)
        #expect(failure.owner == nil)
        #expect(try !UsageStore.shouldPreservePriorSnapshot(
            after: failure, hadPriorData: true, priorSnapshot: Self.snapshot()))
        #expect(try !UsageStore.shouldPreservePriorSnapshot(
            after: URLError(.timedOut), hadPriorData: true, priorSnapshot: Self.snapshot()))
        #expect(try !UsageStore.shouldSuppressProviderCancellation(
            CancellationError(), priorSnapshot: Self.snapshot()))
    }
}
#endif
