import Foundation

/// Modern agy can query quota without a model turn or a tokenless localhost server.
enum AntigravityNativeUsage {
    static func fetch(binary: String, environment: [String: String]) async throws -> UsageSnapshot {
        let result = try await SubprocessRunner.run(
            binary: binary,
            arguments: ["-p", "/usage", "--output-format", "json"],
            environment: environment,
            // agy may spend about a minute on its eligibility check before emitting
            // the read-only response. Keep this bounded while avoiding a false fallback.
            timeout: 120,
            standardInput: FileHandle.nullDevice,
            label: "antigravity-native-usage")
        return try self.parse(Data(result.stdout.utf8)).toUsageSnapshot()
    }

    static func parse(_ data: Data) throws -> AntigravityStatusSnapshot {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.status == "SUCCESS", response.command.name == "usage",
              response.numTurns == 0, response.usage.totalTokens == 0,
              !response.command.data.groups.isEmpty
        else {
            throw AntigravityStatusProbeError.parseFailed("Not a read-only agy usage response")
        }
        let groups = try response.command.data.groups.map { group in
            let buckets = try group.buckets.map { bucket in
                guard bucket.remainingFraction.isFinite, (0...1).contains(bucket.remainingFraction),
                      !bucket.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw AntigravityStatusProbeError.parseFailed("Invalid agy quota fraction")
                }
                return AntigravityQuotaSummaryBucket(
                    bucketId: bucket.id.trimmingCharacters(in: .whitespacesAndNewlines),
                    displayName: bucket.name,
                    remainingFraction: bucket.remainingFraction,
                    resetTime: bucket.resetTime.flatMap { ISO8601DateFormatter().date(from: $0) },
                    resetDescription: bucket.description,
                    disabled: false)
            }
            guard !buckets.isEmpty else {
                throw AntigravityStatusProbeError.parseFailed("Missing agy quota buckets")
            }
            return AntigravityQuotaSummaryGroup(
                displayName: group.name,
                description: group.description,
                buckets: buckets)
        }
        // /usage does not identify the account. Never attach the selected OAuth identity.
        return AntigravityStatusSnapshot(
            quotaSummary: AntigravityQuotaSummary(description: nil, groups: groups),
            accountEmail: nil,
            accountPlan: nil)
    }

    private struct Response: Decodable {
        let status: String
        let numTurns: Int
        let usage: Usage
        let command: Command
        enum CodingKeys: String, CodingKey { case status, numTurns = "num_turns", usage, command }
    }

    private struct Usage: Decodable {
        let totalTokens: Int
        enum CodingKeys: String, CodingKey { case totalTokens = "total_tokens" }
    }

    private struct Command: Decodable {
        let name: String
        let data: Payload
    }

    private struct Payload: Decodable { let groups: [Group] }
    private struct Group: Decodable {
        let name: String
        let description: String?
        let buckets: [Bucket]
    }

    private struct Bucket: Decodable {
        let id: String
        let name: String
        let description: String?
        let remainingFraction: Double
        let resetTime: String?
        enum CodingKeys: String, CodingKey {
            case id, name, description
            case remainingFraction = "remaining_fraction"
            case resetTime = "reset_time"
        }
    }
}
