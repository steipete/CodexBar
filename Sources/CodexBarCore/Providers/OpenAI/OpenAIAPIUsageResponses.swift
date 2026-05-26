import Foundation

struct CostsResponse: Decodable {
    let data: [OpenAICostBucket]
}

struct OpenAICostBucket: Decodable {
    let startTime: Int
    let endTime: Int
    let results: [OpenAICostResult]

    private enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

struct OpenAICostResult: Decodable {
    struct Amount: Decodable {
        let value: Double?
        let currency: String?

        private enum CodingKeys: String, CodingKey {
            case value
            case currency
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.value = try container.decodeFlexibleDoubleIfPresent(forKey: .value)
            self.currency = try container.decodeIfPresent(String.self, forKey: .currency)
        }
    }

    let amount: Amount?
    let lineItem: String?

    private enum CodingKeys: String, CodingKey {
        case amount
        case lineItem = "line_item"
    }
}

struct CompletionsUsageResponse: Decodable {
    let data: [OpenAICompletionsUsageBucket]
}

struct OpenAICompletionsUsageBucket: Decodable {
    let startTime: Int
    let endTime: Int
    let results: [OpenAICompletionsUsageResult]

    private enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case results
    }
}

struct OpenAICompletionsUsageResult: Decodable {
    let inputTokens: Int?
    let inputCachedTokens: Int?
    let inputAudioTokens: Int?
    let outputTokens: Int?
    let outputAudioTokens: Int?
    let numModelRequests: Int?
    let model: String?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case inputAudioTokens = "input_audio_tokens"
        case outputTokens = "output_tokens"
        case outputAudioTokens = "output_audio_tokens"
        case numModelRequests = "num_model_requests"
        case model
    }
}

extension KeyedDecodingContainer {
    fileprivate func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard self.contains(key), try !self.decodeNil(forKey: key) else {
            return nil
        }

        if let value = try? self.decode(Double.self, forKey: key) {
            return value
        }

        if let rawValue = try? self.decode(String.self, forKey: key) {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            if let value = Double(trimmed) {
                return value
            }
        }

        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected a number or numeric string for \(key.stringValue)")
    }
}
