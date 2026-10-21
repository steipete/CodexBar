import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Optional dates from Claude's authenticated subscription_details response, separate from quota resets.
public struct ClaudeSubscriptionMetadata: Equatable, Sendable {
    public struct BillingDate: Equatable, Sendable {
        public let date: Date
        public let isDateOnly: Bool
    }

    public let renews: BillingDate?
    public let expires: BillingDate?

    public func applying(to snapshot: UsageSnapshot) -> UsageSnapshot {
        snapshot.withSubscriptionMetadata(
            expiresAt: self.expires?.date,
            renewsAt: self.renews?.date,
            expiresAtIsDateOnly: self.expires?.isDateOnly ?? false,
            renewsAtIsDateOnly: self.renews?.isDateOnly ?? false)
    }

    public static func parse(_ data: Data) throws -> Self {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let fields = object as? [String: Any], let status = fields["status"] as? String,
              ["active", "trialing", "canceled"].contains(status),
              fields.keys.contains("next_charge_at"), fields.keys.contains("next_charge_date"),
              fields.keys.contains("plan_ending_at"), fields.keys.contains("plan_ending_before")
        else { throw ParseError.unrecognized }
        func date(_ key: String) throws -> BillingDate? {
            guard let value = fields[key], !(value is NSNull) else { return nil }
            guard let string = value as? String else { throw ParseError.unrecognized }
            if string.count == 10 {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.isLenient = false
                guard let parsed = formatter.date(from: string), formatter.string(from: parsed) == string else {
                    throw ParseError.unrecognized
                }
                return BillingDate(date: parsed, isDateOnly: true)
            }
            guard let parsed = ISO8601DateParser.parse(string) else {
                throw ParseError.unrecognized
            }
            return BillingDate(date: parsed, isDateOnly: false)
        }
        let end = try date("plan_ending_at") ?? date("plan_ending_before")
        // A scheduled ending takes precedence over a next-charge value left in the same response.
        let renewal = end == nil && ["active", "trialing"].contains(status)
            ? try date("next_charge_at") ?? date("next_charge_date") : nil
        return Self(renews: renewal, expires: end)
    }

    public enum ParseError: Error { case unrecognized }
}

public enum ClaudeSubscriptionFetchResult: Equatable, Sendable {
    case unavailable
    /// A recognized response with two nil dates is authoritative empty metadata.
    case available(ClaudeSubscriptionMetadata)
}

public enum ClaudeSubscriptionMetadataFetcher {
    #if DEBUG
    @TaskLocal static var timeoutForTesting: Duration?
    #endif

    /// Resolves ownership from the OAuth token used for the accepted usage capture.
    public static func oauthOwner(
        accessToken: String, transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async -> String?
    {
        let fresh = ProviderHTTPTransportHandler { request in
            var request = request
            request.cachePolicy = .reloadIgnoringLocalCacheData
            return try await transport.data(for: request)
        }
        guard let profile = try? await ClaudeOAuthUsageFetcher.fetchProfile(
            accessToken: accessToken, transport: fresh) else { return nil }
        return ClaudeVerifiedAccountOwner.ownerID(
            accountUUID: profile.accountUuid,
            email: profile.emailAddress,
            organizationUUID: profile.organizationUuid)
    }

    /// Uses ONLY an existing, verified web-owner binding. No cookie discovery or credential mutation.
    public static func fetch(
        cookieHeader: String,
        expectedOwnerID: String?,
        oauthAccessToken: String? = nil,
        transport: (any ProviderHTTPTransport)? = nil) async -> ClaudeSubscriptionFetchResult
    {
        let worker = Task<ClaudeSubscriptionFetchResult, Error> {
            await self.fetchVerified(
                cookieHeader: cookieHeader,
                expectedOwnerID: expectedOwnerID,
                oauthAccessToken: oauthAccessToken,
                transport: transport ?? ClaudeWebHTTPTransport.current)
        }
        #if DEBUG
        let timeout = self.timeoutForTesting ?? .seconds(2)
        #else
        let timeout: Duration = .seconds(2)
        #endif
        switch await BoundedTaskJoin(sourceTask: worker).value(joinGrace: timeout) {
        case let .value(result): return result
        case .failure, .timedOut: return .unavailable
        }
    }

    private static func fetchVerified(
        cookieHeader: String,
        expectedOwnerID: String?,
        oauthAccessToken: String?,
        transport: any ProviderHTTPTransport) async -> ClaudeSubscriptionFetchResult
    {
        do {
            let owner: String?
            if let oauthAccessToken {
                owner = await self.oauthOwner(accessToken: oauthAccessToken, transport: transport)
                guard let owner, expectedOwnerID == nil || owner == expectedOwnerID else { return .unavailable }
            } else {
                owner = expectedOwnerID
            }
            guard let owner else { return .unavailable }
            let session = try ClaudeWebAPIFetcher.sessionKeyInfo(cookieHeader: cookieHeader)
            func get(_ path: String) async throws -> Data {
                var request = URLRequest(url: URL(string: "https://claude.ai/api" + path)!)
                request.setValue("sessionKey=\(session.key)", forHTTPHeaderField: "Cookie")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.httpMethod = "GET"
                request.timeoutInterval = 2
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await transport.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ClaudeSubscriptionMetadata.ParseError.unrecognized
                }
                try Task.checkCancellation()
                return data
            }
            func organization(_ data: Data) throws -> String? {
                guard let account = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let email = account["email_address"] as? String,
                      let memberships = account["memberships"] as? [[String: Any]] else { return nil }
                let matches = memberships.compactMap { membership -> String? in
                    guard let org = membership["organization"] as? [String: Any],
                          let id = org["uuid"] as? String,
                          UUID(uuidString: id) != nil,
                          [nil, account["uuid"] as? String].contains(where: { accountUUID in
                              ClaudeVerifiedAccountOwner.ownerID(
                                  accountUUID: accountUUID, email: email, organizationUUID: id) == owner
                          }) else { return nil }
                    return id
                }
                return matches.count == 1 ? matches.first : nil
            }
            guard let org = try await organization(get("/account")) else { return .unavailable }
            let metadata = try await ClaudeSubscriptionMetadata.parse(get("/organizations/\(org)/subscription_details"))
            // Recheck the authenticated principal + organization after the optional request.
            guard try await organization(get("/account")) == org else { return .unavailable }
            if let oauthAccessToken,
               await self.oauthOwner(accessToken: oauthAccessToken, transport: transport) != owner
            { return .unavailable }
            return .available(metadata)
        } catch { return .unavailable }
    }
}
