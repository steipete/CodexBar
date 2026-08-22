import Foundation

enum GeminiAPITestHelpers {
    static func dataLoader(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data))
        -> @Sendable (URLRequest) async throws -> (Data, URLResponse)
    {
        { request in
            let (response, data) = try handler(request)
            return (data, response)
        }
    }

    static func response(url: String, status: Int, body: Data) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        return (response, body)
    }

    static func jsonData(_ payload: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    static func sampleQuotaResponse() -> Data {
        self.jsonData([
            "buckets": [
                [
                    "modelId": "gemini-2.5-pro",
                    "remainingFraction": 0.6,
                    "resetTime": "2025-01-01T00:00:00Z",
                ],
                [
                    "modelId": "gemini-2.5-flash",
                    "remainingFraction": 0.9,
                    "resetTime": "2025-01-01T00:00:00Z",
                ],
                [
                    "modelId": "gemini-2.5-flash-lite",
                    "remainingFraction": 0.8,
                    "resetTime": "2025-01-01T00:00:00Z",
                ],
            ],
        ])
    }

    static func sampleFlashQuotaResponse() -> Data {
        self.jsonData([
            "buckets": [
                [
                    "modelId": "gemini-2.5-flash",
                    "remainingFraction": 0.9,
                    "resetTime": "2025-01-01T00:00:00Z",
                ],
                [
                    "modelId": "gemini-2.5-flash",
                    "remainingFraction": 0.4,
                    "resetTime": "2025-01-01T00:00:00Z",
                ],
            ],
        ])
    }

    static func makeIDToken(email: String, hostedDomain: String? = nil) -> String {
        var payload: [String: Any] = ["email": email]
        if let hd = hostedDomain {
            payload["hd"] = hd
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        var encoded = data.base64EncodedString()
        encoded = encoded.replacingOccurrences(of: "+", with: "-")
        encoded = encoded.replacingOccurrences(of: "/", with: "_")
        encoded = encoded.replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).sig"
    }

    static func loadCodeAssistResponse(
        tierId: String?,
        projectId: String? = nil,
        paidTierName: String? = nil) -> Data
    {
        var payload: [String: Any] = [:]
        if let tierId {
            payload["currentTier"] = [
                "id": tierId,
                "name": tierId.replacingOccurrences(of: "-tier", with: ""),
            ]
        }
        if let projectId {
            payload["cloudaicompanionProject"] = projectId
        }
        if let paidTierName {
            payload["paidTier"] = [
                "name": paidTierName,
            ]
        }
        return self.jsonData(payload)
    }

    static func loadCodeAssistConsumerPlusResponse(projectId: String? = "cloudaicompanion-123") -> Data {
        self.loadCodeAssistResponse(
            tierId: "free-tier",
            projectId: projectId,
            paidTierName: "Plus")
    }

    static func loadCodeAssistFreeTierResponse() -> Data {
        self.loadCodeAssistResponse(tierId: "free-tier")
    }

    static func loadCodeAssistStandardTierResponse() -> Data {
        self.loadCodeAssistResponse(tierId: "standard-tier")
    }

    static func loadCodeAssistGoogleOneProResponse(projectId: String? = "cloudaicompanion-123") -> Data {
        self.loadCodeAssistResponse(
            tierId: "standard-tier",
            projectId: projectId,
            paidTierName: "Gemini Code Assist in Google One AI Pro")
    }

    static func loadCodeAssistLegacyTierResponse() -> Data {
        self.loadCodeAssistResponse(tierId: "legacy-tier")
    }

    /// Synthetic error-body variant of the migration signal (token refresh / non-200 paths).
    static func consumerTierDeprecationResponse() -> Data {
        self.jsonData([
            "error": [
                "code": 403,
                "message": """
                IneligibleTierError / UNSUPPORTED_CLIENT: This client is no longer supported for \
                Gemini Code Assist for individuals. To continue using Gemini, please migrate to the \
                Antigravity suite of products.
                """,
                "status": "PERMISSION_DENIED",
            ],
        ])
    }

    /// Mirrors the real `loadCodeAssist` HTTP 200 body Google returns to consumer accounts after the
    /// June 2026 shutdown: the free tier is listed under `ineligibleTiers` with `UNSUPPORTED_CLIENT`,
    /// `currentTier` is absent unless the account still holds a tier.
    static func loadCodeAssistUnsupportedClientResponse(
        currentTierId: String? = nil,
        paidTierName: String? = nil) -> Data
    {
        var payload: [String: Any] = [
            "allowedTiers": [
                [
                    "id": "standard-tier",
                    "name": "Gemini Code Assist",
                    "userDefinedCloudaicompanionProject": true,
                    "isDefault": true,
                ],
            ],
            "ineligibleTiers": [
                [
                    "reasonCode": "UNSUPPORTED_CLIENT",
                    "reasonMessage": """
                    This client is no longer supported for Gemini Code Assist for individuals. \
                    To continue using Gemini, please migrate to the Antigravity suite of products: \
                    https://antigravity.google
                    """,
                    "tierId": "free-tier",
                    "tierName": "Gemini Code Assist for individuals",
                ],
            ],
        ]
        if let currentTierId {
            payload["currentTier"] = ["id": currentTierId, "name": currentTierId]
        }
        if let paidTierName {
            payload["paidTier"] = ["name": paidTierName]
        }
        return self.jsonData(payload)
    }

    /// Mirrors the real `retrieveUserQuota` HTTP 403 body for an account without a Code Assist license.
    /// Note: it carries no migration wording, so text matching alone cannot classify it.
    static func quotaSubscriptionRequiredResponse() -> Data {
        self.jsonData([
            "error": [
                "code": 403,
                "message": """
                You do not have a valid license of this product. Please contact your administrator \
                to request a license. (#3501)
                """,
                "status": "PERMISSION_DENIED",
                "details": [
                    [
                        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
                        "reason": "SUBSCRIPTION_REQUIRED",
                        "domain": "cloudaicompanion.googleapis.com",
                    ],
                ],
            ],
        ])
    }
}
