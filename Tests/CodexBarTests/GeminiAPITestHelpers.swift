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

    static func loadCodeAssistResponse(tierId: String) -> Data {
        self.jsonData([
            "currentTier": [
                "id": tierId,
                "name": tierId.replacingOccurrences(of: "-tier", with: ""),
            ],
        ])
    }

    static func loadCodeAssistFreeTierResponse() -> Data {
        self.loadCodeAssistResponse(tierId: "free-tier")
    }

    static func loadCodeAssistStandardTierResponse() -> Data {
        self.loadCodeAssistResponse(tierId: "standard-tier")
    }

    static func loadCodeAssistLegacyTierResponse() -> Data {
        self.loadCodeAssistResponse(tierId: "legacy-tier")
    }
}
