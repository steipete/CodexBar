import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum AntigravityQuota {
    private struct Project: Decodable {
        let id: String?
        let projectId: String?
    }

    private struct CodeAssist: Decodable {
        let projectID: String?
        let rejectedClient: Bool

        enum Keys: String, CodingKey { case cloudaicompanionProject, currentTier, ineligibleTiers }
        private struct Tier: Decodable { let reasonCode: String? }

        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: Keys.self)
            let project = try? root.decode(Project.self, forKey: .cloudaicompanionProject)
            self.projectID = (try? root.decode(String.self, forKey: .cloudaicompanionProject))
                ?? project?.id ?? project?.projectId
            let reasons = try root.decodeIfPresent([Tier].self, forKey: .ineligibleTiers)
            let hasTier = root.contains(.currentTier) && (try? root.decodeNil(forKey: .currentTier)) == false
            self.rejectedClient = !hasTier && self.projectID == nil
                && reasons?.contains { $0.reasonCode == "GOOGLE_TOS_NOT_SUPPORTED_BY_CLIENT" } == true
        }
    }

    static func fetch(
        _ grant: AntigravityOAuthCredentials,
        http: QuotaHTTP,
        save: @Sendable (AntigravityOAuthCredentials) throws -> Void) async throws -> [QuotaWindow]
    {
        let token: String
        if let expiry = grant.expiryDate, expiry.timeIntervalSinceNow <= 60 {
            let renewed = try await self.renew(grant, http: http)
            try save(renewed)
            guard let access = renewed.accessToken else { throw QuotaError.unauthorized }
            token = access
        } else {
            guard let access = grant.accessToken?.trimmedNonEmpty else { throw QuotaError.unauthorized }
            token = access
        }

        let info = try await self.request(
            "loadCodeAssist", body: ["metadata": AntigravityRemoteClient.clientMetadata], token: token, http: http)
        let assist = try JSONDecoder().decode(CodeAssist.self, from: info)
        guard !assist.rejectedClient else { throw QuotaError.unauthorized }
        let project = assist.projectID?.trimmedNonEmpty ?? grant.projectID?.trimmedNonEmpty
        let body = project.map { ["project": $0] } ?? [:]
        do {
            let data = try await self.request("retrieveUserQuotaSummary", body: body, token: token, http: http)
            let windows = try self.summary(data)
            if !windows.isEmpty { return windows }
        } catch let QuotaError.http(status) where [403, 404, 501].contains(status) {
            // Earlier accounts expose measured model buckets through retrieveUserQuota.
        }
        let data = try await self.request("retrieveUserQuota", body: body, token: token, http: http)
        let buckets = try JSONDecoder().decode(ModelQuotas.self, from: data)
        return (buckets.buckets ?? []).compactMap { bucket in
            guard let model = bucket.modelId?.trimmedNonEmpty else { return nil }
            return self.window(title: model, remaining: bucket.remainingFraction, reset: bucket.resetTime)
        }
    }

    private struct ModelQuotas: Decodable {
        struct Bucket: Decodable {
            let modelId: String?
            let remainingFraction: Double?
            let resetTime: String?
        }

        let buckets: [Bucket]?
    }

    private struct Summary: Decodable {
        let response: QuotaSummaryPayload?
        let summary: QuotaSummaryPayload?
        let groups: [QuotaSummaryGroupPayload]?
    }

    static func summary(_ data: Data) throws -> [QuotaWindow] {
        let envelope = try JSONDecoder().decode(Summary.self, from: data)
        let groups = envelope.response?.groups ?? envelope.summary?.groups ?? envelope.groups ?? []
        return groups.flatMap { group in
            (group.buckets ?? []).compactMap { bucket -> QuotaWindow? in
                guard bucket.disabled != true,
                      let name = (bucket.displayName ?? bucket.name ?? bucket.bucketId ?? bucket.id)?.trimmedNonEmpty
                else { return nil }
                let cadence = bucket.window?.trimmedNonEmpty
                let parts = [group.displayName ?? group.name, name, cadence == name ? nil : cadence]
                return self.window(
                    title: parts.compactMap(\.self).joined(separator: " · "),
                    remaining: bucket.remainingFraction ?? bucket.remaining?.remainingFraction, reset: bucket.resetTime)
            }
        }
    }

    private static func window(title: String, remaining: Double?, reset: String?) -> QuotaWindow? {
        guard let remaining, (0...1).contains(remaining), let fraction = Decimal(string: String(remaining))
        else { return nil }
        let date = ISO8601DateParser.parse(reset) ?? reset.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return QuotaWindow(title: title, usedPercent: (1 - fraction) * 100, resetsAt: date)
    }

    private static func request(
        _ method: String, body: [String: Any], token: String, http: QuotaHTTP) async throws -> Data
    {
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:\(method)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AntigravityRemoteClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await http.send(request)
    }

    private static func renew(_ grant: AntigravityOAuthCredentials, http: QuotaHTTP) async throws
        -> AntigravityOAuthCredentials
    {
        guard let refresh = grant.refreshToken?.trimmedNonEmpty,
              let client = grant.clientID?.trimmedNonEmpty,
              let secret = grant.clientSecret?.trimmedNonEmpty else { throw QuotaError.unauthorized }
        var request = URLRequest(url: AntigravityOAuthConfig.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoding.body([
            "client_id": client, "client_secret": secret, "refresh_token": refresh, "grant_type": "refresh_token",
        ])
        struct Token: Decodable {
            let access_token: String
            let expires_in: Double
            let refresh_token: String?
        }
        let data: Data
        do {
            data = try await http.send(request)
        } catch QuotaError.http(400) {
            throw QuotaError.unauthorized
        }
        let response = try JSONDecoder().decode(Token.self, from: data)
        guard let access = response.access_token.trimmedNonEmpty, response.expires_in > 0 else {
            throw QuotaError.unauthorized
        }
        var renewed = grant
        renewed.accessToken = access
        renewed.refreshToken = response.refresh_token?.trimmedNonEmpty ?? refresh
        renewed.expiryDateMilliseconds = Date().addingTimeInterval(response.expires_in).timeIntervalSince1970 * 1000
        return renewed
    }
}
