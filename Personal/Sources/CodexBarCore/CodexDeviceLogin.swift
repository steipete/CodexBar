import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CodexGrant: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let accountID: String?
}

enum CodexDeviceLogin {
    private static let issuer = "https://auth.openai.com"
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private struct Challenge: Decodable {
        let device_auth_id: String
        let user_code: String?
        let usercode: String?
        let interval: String?
    }

    private struct Approval: Decodable {
        let authorization_code: String
        let code_verifier: String
    }

    static func signIn(http: QuotaHTTP, present: @Sendable (String) async throws -> Void) async throws -> CodexGrant {
        let challengeData = try await self.post("api/accounts/deviceauth/usercode", ["client_id": self.clientID], http)
        let challenge = try JSONDecoder().decode(Challenge.self, from: challengeData)
        guard let code = (challenge.user_code ?? challenge.usercode)?.trimmedNonEmpty else {
            throw QuotaError.unauthorized
        }
        try await present(code)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(900))
        let delay = max(1, Int(challenge.interval ?? "") ?? 5)
        while clock.now < deadline {
            try Task.checkCancellation()
            let data: Data
            do {
                data = try await self.post("api/accounts/deviceauth/token", [
                    "device_auth_id": challenge.device_auth_id, "user_code": code,
                ], http)
            } catch let QuotaError.http(status) where status == 403 || status == 404 {
                try await clock.sleep(until: min(deadline, clock.now.advanced(by: .seconds(min(900, delay)))))
                continue
            }
            let approval = try JSONDecoder().decode(Approval.self, from: data)
            var request = URLRequest(url: URL(string: "\(self.issuer)/oauth/token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = FormURLEncoding.body([
                "grant_type": "authorization_code", "client_id": self.clientID, "code": approval.authorization_code,
                "code_verifier": approval.code_verifier, "redirect_uri": "\(self.issuer)/deviceauth/callback",
            ])
            let tokens = try await http.send(request)
            return try self.grant(tokens, previous: nil)
        }
        throw URLError(.timedOut)
    }

    static func refresh(_ grant: CodexGrant, http: QuotaHTTP) async throws -> CodexGrant {
        do {
            let data = try await self.post("oauth/token", [
                "client_id": self.clientID, "grant_type": "refresh_token", "refresh_token": grant.refreshToken,
            ], http)
            return try self.grant(data, previous: grant)
        } catch QuotaError.http(400) {
            throw QuotaError.unauthorized
        }
    }

    private static func grant(_ data: Data, previous: CodexGrant?) throws -> CodexGrant {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let id_token: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let access = response.access_token.trimmedNonEmpty,
              let refresh = response.refresh_token?.trimmedNonEmpty ?? previous?.refreshToken
        else { throw QuotaError.unauthorized }
        let account = [response.id_token, access].compactMap { token -> String? in
            let payload = AntigravityOAuthCredentials.claims(fromIDToken: token)
            let auth = payload?["https://api.openai.com/auth"] as? [String: Any]
            return (auth?["chatgpt_account_id"] ?? payload?["chatgpt_account_id"]) as? String
        }.first
        return CodexGrant(accessToken: access, refreshToken: refresh, accountID: account ?? previous?.accountID)
    }

    private static func post(_ path: String, _ body: [String: String], _ http: QuotaHTTP) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(self.issuer)/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await http.send(request)
    }
}

extension QuotaService {
    package func connectCodex(present: @Sendable (String) async throws -> Void) async throws {
        let grant = try await CodexDeviceLogin.signIn(http: self.http, present: present)
        try Task.checkCancellation()
        try self.credentials.saveCodex(grant)
    }
}
