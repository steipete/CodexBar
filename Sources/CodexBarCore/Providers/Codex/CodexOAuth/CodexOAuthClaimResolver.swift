import Foundation

public enum CodexOAuthClaimResolver {
    public static func accountID(accessToken: String?, idToken: String?) -> String? {
        if let value = self.stringClaim(
            named: "chatgpt_account_id",
            inNamespace: "https://api.openai.com/auth",
            token: accessToken)
        {
            return value
        }
        if let value = self.stringClaim(named: "account_id", inNamespace: nil, token: accessToken) {
            return value
        }
        if let value = self.stringClaim(
            named: "chatgpt_account_id",
            inNamespace: "https://api.openai.com/auth",
            token: idToken)
        {
            return value
        }
        return self.stringClaim(named: "account_id", inNamespace: nil, token: idToken)
    }

    public static func email(accessToken: String?, idToken: String?) -> String? {
        if let value = self.stringClaim(named: "email", inNamespace: nil, token: idToken) {
            return value
        }
        if let value = self.stringClaim(named: "email", inNamespace: "https://api.openai.com/profile", token: idToken) {
            return value
        }
        if let value = self.stringClaim(named: "email", inNamespace: nil, token: accessToken) {
            return value
        }
        return self.stringClaim(named: "email", inNamespace: "https://api.openai.com/profile", token: accessToken)
    }

    public static func plan(accessToken: String?, idToken: String?) -> String? {
        if let value = self.stringClaim(
            named: "chatgpt_plan_type",
            inNamespace: "https://api.openai.com/auth",
            token: idToken)
        {
            return value
        }
        if let value = self.stringClaim(named: "chatgpt_plan_type", inNamespace: nil, token: idToken) {
            return value
        }
        if let value = self.stringClaim(
            named: "chatgpt_plan_type",
            inNamespace: "https://api.openai.com/auth",
            token: accessToken)
        {
            return value
        }
        return self.stringClaim(named: "chatgpt_plan_type", inNamespace: nil, token: accessToken)
    }

    private static func stringClaim(named name: String, inNamespace namespace: String?, token: String?) -> String? {
        guard let token, let payload = UsageFetcher.parseJWT(token) else { return nil }
        let raw: String? = if let namespace,
                              let dict = payload[namespace] as? [String: Any]
        {
            dict[name] as? String
        } else {
            payload[name] as? String
        }
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
