import Foundation

/// Cross-platform DeepSeek bearer-token validation and session sanitization.
enum DeepSeekSessionAuthorization {
    static func sanitized(_ session: DeepSeekPlatformSession) -> DeepSeekPlatformSession {
        guard let authorizationHeader = session.authorizationHeader,
              !authorizationHeader.isEmpty
        else {
            return session
        }
        guard self.looksLikeDeepSeekAuthorizationHeader(authorizationHeader) else {
            return DeepSeekPlatformSession(
                cookieHeader: session.cookieHeader,
                authorizationHeader: nil)
        }
        return session
    }

    static func bearer(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("bearer ") {
            return trimmed
        }
        if self.looksLikeJWT(trimmed) {
            return "Bearer \(trimmed)"
        }
        if let json = self.jsonObject(from: trimmed) {
            if let value = json["value"] as? String, let bearer = self.bearer(from: value) {
                return bearer
            }
            for key in ["token", "access_token", "accessToken", "auth_token"] {
                if let value = json[key] as? String, let bearer = self.bearer(from: value) {
                    return bearer
                }
            }
        }
        if self.looksLikeDeepSeekPlatformToken(trimmed) {
            return "Bearer \(trimmed)"
        }
        return nil
    }

    static func looksLikeJWT(_ raw: String) -> Bool {
        let parts = raw.split(separator: ".")
        return parts.count == 3 && raw.hasPrefix("eyJ") && raw.count > 40
    }

    static func looksLikeDeepSeekPlatformToken(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 40, !token.hasPrefix("eyJ") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=_-"))
        return token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func looksLikeDeepSeekAuthorizationHeader(_ authorizationHeader: String) -> Bool {
        let token = authorizationHeader
            .replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if self.looksLikeJWT(token) {
            return self.looksLikeDeepSeekJWT(authorizationHeader)
        }
        return self.looksLikeDeepSeekPlatformToken(token)
    }

    static func looksLikeDeepSeekJWT(_ authorizationHeader: String) -> Bool {
        let token = authorizationHeader
            .replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.looksLikeJWT(token), let payload = self.jwtPayload(from: token) else { return false }

        if payload["firebase"] != nil { return false }
        if let aud = payload["aud"] as? String, aud == "writefull" { return false }
        if let type = payload["type"] as? String, type == "websocket" { return false }
        if let iss = payload["iss"] as? String,
           iss.contains("google") || iss.contains("firebase") || iss.contains("jetbrains")
        {
            return false
        }
        if let exp = payload["exp"] as? TimeInterval {
            guard exp > Date().timeIntervalSince1970 else { return false }
        } else if let exp = payload["exp"] as? Int {
            guard TimeInterval(exp) > Date().timeIntervalSince1970 else { return false }
        } else if let exp = payload["exp"] as? NSNumber {
            guard exp.doubleValue > Date().timeIntervalSince1970 else { return false }
        } else {
            return false
        }

        if let iss = payload["iss"] as? String {
            let lower = iss.lowercased()
            if lower.contains("openai") || lower.contains("google") || lower.contains("firebase")
                || lower.contains("jetbrains") || lower.contains("auth0")
            {
                return false
            }
        }

        return self.looksLikeDeepSeekIdentity(payload)
    }

    static func authorizationHeader(from storage: [String: String]) -> String? {
        let storageTokenKeys = [
            "auth_token",
            "access_token",
            "accessToken",
            "token",
            "userToken",
            "platform_token",
        ]
        for key in storageTokenKeys {
            guard let value = storage[key] else { continue }
            if let bearer = self.bearer(from: value), self.looksLikeDeepSeekAuthorizationHeader(bearer) {
                return bearer
            }
        }

        for (key, value) in storage where key.lowercased().contains("token") {
            guard let bearer = self.bearer(from: value),
                  self.looksLikeDeepSeekAuthorizationHeader(bearer) else { continue }
            return bearer
        }

        return nil
    }

    private static func looksLikeDeepSeekIdentity(_ payload: [String: Any]) -> Bool {
        if payload["openid"] != nil { return false }
        if payload["auth_provider"] != nil { return false }
        if payload["role"] != nil, payload["email"] == nil { return false }
        if let email = payload["email"] as? String, email.contains("@") {
            return true
        }
        if let sub = payload["sub"] as? String, !sub.isEmpty, sub.allSatisfy(\.isNumber) {
            return true
        }
        return false
    }

    private static func jsonObject(from raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func jwtPayload(from token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }
}
