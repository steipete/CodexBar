import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OpenAILiveUsageError: Error, LocalizedError, Sendable, Equatable {
    case missingCredential
    case adminKeyRequired
    case rateLimited
    case apiFailure(Int)
    case parseFailure
    case invalidWindow

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            "Configure an OpenAI organization Admin API key in Settings → Providers → OpenAI."
        case .adminKeyRequired:
            "Live usage needs an OpenAI organization Admin API key (sk-admin-…). " +
                "Project and service-account keys cannot read organization usage."
        case .rateLimited:
            "OpenAI live usage is rate limited."
        case let .apiFailure(status):
            "OpenAI live usage API failed (HTTP \(status))."
        case .parseFailure:
            "Could not parse the OpenAI live usage response."
        case .invalidWindow:
            "OpenAI live usage supports 15-minute, 1-hour, and 6-hour windows."
        }
    }
}

public struct OpenAILiveUsageFetcher: Sendable {
    private let transport: any ProviderHTTPTransport

    public init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
    }

    public static func hasCredential(environment: [String: String]) -> Bool {
        OpenAIAPIUsageCredential(environment: environment) != nil
    }

    public func fetch(
        environment: [String: String],
        windowMinutes: Int = 60,
        now: Date = Date()) async throws -> OpenAILiveUsageSnapshot
    {
        guard [15, 60, 360].contains(windowMinutes) else { throw OpenAILiveUsageError.invalidWindow }
        guard let credential = OpenAIAPIUsageCredential(environment: environment) else {
            throw OpenAILiveUsageError.missingCredential
        }
        let currentMinute = Int(floor(now.timeIntervalSince1970 / 60)) * 60
        let firstMinute = currentMinute - (windowMinutes - 1) * 60
        var buckets: [OpenAILiveUsageSnapshot.Minute] = []
        var cursor: String?
        var cursors: Set<String> = []
        for _ in 0..<20 {
            try Task.checkCancellation()
            let request = Self.request(
                credential: credential,
                start: firstMinute,
                end: Int(now.timeIntervalSince1970),
                limit: windowMinutes,
                cursor: cursor)
            let response = try await self.transport.response(for: request)
            switch response.statusCode {
            case 200..<300: break
            case 401, 403: throw OpenAILiveUsageError.adminKeyRequired
            case 429: throw OpenAILiveUsageError.rateLimited
            default: throw OpenAILiveUsageError.apiFailure(response.statusCode)
            }
            let page: Page
            do {
                page = try JSONDecoder().decode(Page.self, from: response.data)
                for bucket in page.data {
                    guard bucket.startTime >= 0 else { throw OpenAILiveUsageError.parseFailure }
                    for result in bucket.results {
                        try result.validate()
                    }
                    buckets.append(.init(
                        start: Date(timeIntervalSince1970: Double(bucket.startTime)),
                        models: bucket.results.map(\.usage)))
                }
            } catch {
                throw OpenAILiveUsageError.parseFailure
            }
            if !page.hasMore {
                return try OpenAILiveUsageBuilder.build(
                    buckets: buckets, windowMinutes: windowMinutes, fetchedAt: now, projectID: credential.projectID)
            }
            guard let next = page.nextPage, !next.isEmpty, cursors.insert(next).inserted else {
                throw OpenAILiveUsageError.parseFailure
            }
            cursor = next
        }
        throw OpenAILiveUsageError.parseFailure
    }

    private static func request(
        credential: OpenAIAPIUsageCredential,
        start: Int,
        end: Int,
        limit: Int,
        cursor: String?) -> URLRequest
    {
        var url = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")!
        url.queryItems = [
            URLQueryItem(name: "start_time", value: String(start)),
            URLQueryItem(name: "end_time", value: String(end)),
            URLQueryItem(name: "bucket_width", value: "1m"),
            URLQueryItem(name: "group_by", value: "model"),
            URLQueryItem(name: "group_by", value: "batch"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let projectID = credential.projectID {
            url.queryItems?.append(URLQueryItem(name: "project_ids", value: projectID))
        }
        if let cursor { url.queryItems?.append(URLQueryItem(name: "page", value: cursor)) }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }
}

private struct Page: Decodable {
    let data: [Bucket]
    let hasMore: Bool
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data, hasMore = "has_more", nextPage = "next_page"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.data = try values.decode([Bucket].self, forKey: .data)
        self.hasMore = try values.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        self.nextPage = try values.decodeIfPresent(String.self, forKey: .nextPage)
    }
}

private struct Bucket: Decodable {
    let startTime: Int
    let results: [Result]

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time", results
    }
}

private struct Result: Decodable {
    let model: String?
    let batch: Bool?
    let input: Int
    let cached: Int
    let output: Int
    let requests: Int
    let inputAudio: Int
    let outputAudio: Int

    enum CodingKeys: String, CodingKey {
        case model, batch, input = "input_tokens", cached = "input_cached_tokens", output = "output_tokens"
        case requests = "num_model_requests", inputAudio = "input_audio_tokens", outputAudio = "output_audio_tokens"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try values.decodeIfPresent(String.self, forKey: .model)
        self.batch = try values.decodeIfPresent(Bool.self, forKey: .batch)
        self.input = try values.decodeIfPresent(Int.self, forKey: .input) ?? 0
        self.cached = try values.decodeIfPresent(Int.self, forKey: .cached) ?? 0
        self.output = try values.decodeIfPresent(Int.self, forKey: .output) ?? 0
        self.requests = try values.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        self.inputAudio = try values.decodeIfPresent(Int.self, forKey: .inputAudio) ?? 0
        self.outputAudio = try values.decodeIfPresent(Int.self, forKey: .outputAudio) ?? 0
    }

    func validate() throws {
        let (total, overflow) = self.input.addingReportingOverflow(self.output)
        guard !overflow, total <= 9_007_199_254_740_991 else { throw OpenAILiveUsageError.parseFailure }
        guard [self.input, self.cached, self.output, self.requests, self.inputAudio, self.outputAudio]
            .allSatisfy({ $0 >= 0 }), self.cached <= self.input
        else { throw OpenAILiveUsageError.parseFailure }
    }

    var usage: OpenAILiveUsageSnapshot.ModelUsage {
        let name = self.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .init(
            name: name.isEmpty ? "unknown" : name,
            // input/output already aggregate text, audio, and image; the audio fields are only breakdowns.
            inputTokens: self.input,
            cachedInputTokens: self.cached,
            outputTokens: self.output,
            requests: self.requests,
            batchTokens: self.batch == true ? self.input + self.output : 0,
            batchRequests: self.batch == true ? self.requests : 0)
    }
}

/// Which credential and project a resolved environment points at; other settings in the environment (such as
/// OPENAI_LIVE_MINUTES) never change it. The key is kept only as a process-local digest.
public struct OpenAILiveUsageScope: Equatable, Sendable {
    private let credentialDigest: Int
    private let projectID: String?

    public init?(environment: [String: String]) {
        guard let credential = OpenAIAPIUsageCredential(environment: environment) else { return nil }
        var hasher = Hasher()
        hasher.combine(credential.apiKey)
        self.credentialDigest = hasher.finalize()
        self.projectID = credential.projectID
    }
}
