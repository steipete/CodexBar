import Foundation

public enum QwenCodeUsageProbeError: LocalizedError, Sendable, Equatable {
    case projectsDirectoryMissing(String)
    case noChatLogsFound
    case invalidRequestLimit(Int)

    public var errorDescription: String? {
        switch self {
        case let .projectsDirectoryMissing(path):
            "Qwen Code projects directory not found at \(path). Run qwen at least once to create logs."
        case .noChatLogsFound:
            "No Qwen Code chat logs found. Start a session and try again."
        case let .invalidRequestLimit(limit):
            "Qwen Code daily request limit is invalid (\(limit)). Set a positive value in Settings."
        }
    }
}

public struct QwenCodeUsageProbe: Sendable {
    public static let defaultDailyRequestLimit = 2000

    private static let qwenDirName = ".qwen"
    private static let projectsDirName = "projects"
    private static let chatsDirName = "chats"
    private static let oauthCredsFile = "oauth_creds.json"

    private let requestLimit: Int
    private let baseDirectory: URL
    private let now: Date

    public init(requestLimit: Int, baseDirectory: URL, now: Date = Date()) {
        self.requestLimit = requestLimit
        self.baseDirectory = baseDirectory
        self.now = now
    }

    public static func resolveBaseDirectory(env: [String: String]) -> URL {
        if let override = env["CODEXBAR_QWEN_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if let override = env["QWEN_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(self.qwenDirName)
    }

    public static func projectsDirectoryExists(baseDirectory: URL) -> Bool {
        let projectsURL = baseDirectory.appendingPathComponent(self.projectsDirName)
        return FileManager.default.fileExists(atPath: projectsURL.path)
    }

    public func fetch() throws -> QwenCodeUsageSnapshot {
        guard self.requestLimit > 0 else {
            throw QwenCodeUsageProbeError.invalidRequestLimit(self.requestLimit)
        }

        let projectsURL = self.baseDirectory.appendingPathComponent(Self.projectsDirName)
        guard FileManager.default.fileExists(atPath: projectsURL.path) else {
            throw QwenCodeUsageProbeError.projectsDirectoryMissing(projectsURL.path)
        }

        let (windowStart, windowEnd) = self.dailyWindow(now: self.now)
        var totalRequests = 0
        var totalTokens = 0
        var sawAnyLogs = false

        let projectDirs = (try? FileManager.default.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        for projectURL in projectDirs {
            guard projectURL.hasDirectoryPath else { continue }
            let chatsURL = projectURL.appendingPathComponent(Self.chatsDirName)
            guard FileManager.default.fileExists(atPath: chatsURL.path) else { continue }

            let chatFiles = (try? FileManager.default.contentsOfDirectory(
                at: chatsURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])) ?? []

            for fileURL in chatFiles where fileURL.pathExtension == "jsonl" {
                sawAnyLogs = true
                let data = (try? Data(contentsOf: fileURL)) ?? Data()
                guard !data.isEmpty else { continue }
                guard let text = String(bytes: data, encoding: .utf8) else { continue }
                for line in text.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    guard let record = Self.decodeRecord(from: trimmed) else { continue }
                    guard let timestamp = record.timestamp,
                          let date = Self.parseTimestamp(timestamp)
                    else {
                        continue
                    }
                    guard date >= windowStart, date < windowEnd else { continue }
                    guard record.type == "assistant" else { continue }
                    guard let usage = record.usageMetadata else { continue }
                    totalRequests += 1
                    totalTokens += usage.totalTokens
                }
            }
        }

        guard sawAnyLogs else {
            throw QwenCodeUsageProbeError.noChatLogsFound
        }

        let (email, loginMethod) = self.loadIdentity()

        return QwenCodeUsageSnapshot(
            requests: totalRequests,
            totalTokens: totalTokens,
            windowStart: windowStart,
            windowEnd: windowEnd,
            updatedAt: self.now,
            accountEmail: email,
            loginMethod: loginMethod)
    }

    private func dailyWindow(now: Date) -> (Date, Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        return (start, end)
    }

    private func loadIdentity() -> (String?, String?) {
        let credsURL = self.baseDirectory.appendingPathComponent(Self.oauthCredsFile)
        guard let data = try? Data(contentsOf: credsURL),
              let creds = try? JSONDecoder().decode(QwenCodeOAuthCredentials.self, from: data)
        else {
            return (nil, nil)
        }

        let email: String? = creds.idToken.flatMap { token in
            guard let payload = UsageFetcher.parseJWT(token) else { return nil }
            if let raw = payload["email"] as? String {
                return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        return (email, "Qwen OAuth")
    }

    private static func decodeRecord(from line: String) -> QwenCodeChatRecord? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(QwenCodeChatRecord.self, from: data)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractional.date(from: raw) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

private struct QwenCodeOAuthCredentials: Decodable {
    let idToken: String?

    private enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
    }
}

private struct QwenCodeChatRecord: Decodable {
    let type: String?
    let timestamp: String?
    let usageMetadata: QwenCodeUsageMetadata?

    private enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case usageMetadata
    }
}

private struct QwenCodeUsageMetadata: Decodable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let totalTokenCount: Int?
    let cachedContentTokenCount: Int?
    let thoughtsTokenCount: Int?

    var totalTokens: Int {
        if let totalTokenCount {
            return totalTokenCount
        }
        return [
            self.promptTokenCount,
            self.candidatesTokenCount,
            self.cachedContentTokenCount,
            self.thoughtsTokenCount,
        ]
            .compactMap(\.self)
            .reduce(0, +)
    }
}
