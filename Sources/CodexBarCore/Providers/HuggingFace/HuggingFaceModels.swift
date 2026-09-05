import Foundation

/// Tolerant response models for Hugging Face billing/identity endpoints.
/// The usage-v2 path is in the official OpenAPI spec but its response shape is
/// undocumented, so every field is optional and drift funnels into a typed error.
struct HuggingFaceUsageV2Response: Decodable {
    struct Usage: Decodable {
        struct InferenceProviders: Decodable {
            let usedNanoUsd: Double?
            let includedNanoUsd: Double?
            let limitNanoUsd: Double?
            let numRequests: Int?
            let periodEnd: HuggingFaceFlexibleDate?
        }

        let inferenceProviders: InferenceProviders?
    }

    let usage: Usage?
}

struct HuggingFaceZeroGPUQuotaResponse: Decodable {
    let base: Double?
    let current: Double?
    let resetsAt: HuggingFaceFlexibleDate?
}

struct HuggingFaceWhoAmIResponse: Decodable {
    let name: String?
    let fullname: String?
    let email: String?
    let isPro: Bool?
    let periodEnd: Double?
}

/// Decodes a timestamp that Hugging Face may send as Unix seconds or an ISO-8601 string.
struct HuggingFaceFlexibleDate: Decodable {
    let date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            self.date = Date(timeIntervalSince1970: seconds)
            return
        }
        if let text = try? container.decode(String.self) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: text) {
                self.date = parsed
                return
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let parsed = formatter.date(from: text) {
                self.date = parsed
                return
            }
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected Hugging Face timestamp as Unix seconds or an ISO-8601 string.")
    }
}
