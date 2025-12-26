import Foundation

/// Reads and parses Claude's settings.json file to detect z.ai configuration
public struct ClaudeSettingsReader: Sendable {
    private static let log = CodexBarLog.logger("claude-settings")

    /// Cache for settings to avoid repeated file I/O
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedSettings: ClaudeSettings?
    private nonisolated(unsafe) static var cacheTimestamp: Date?
    private static let cacheTTL: TimeInterval = 2.0

    /// Invalidate the cache (call when settings file is known to have changed)
    public static func invalidateCache() {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }
        self.cachedSettings = nil
        self.cacheTimestamp = nil
    }

    /// Get cached settings or fetch using the provided closure
    private static func getCached(path: String, fetch: () -> ClaudeSettings) -> ClaudeSettings {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }

        // Check if we have a valid cache
        if let cached = self.cachedSettings,
           let timestamp = self.cacheTimestamp,
           Date().timeIntervalSince(timestamp) < self.cacheTTL
        {
            return cached
        }

        // Cache miss or expired - fetch and cache
        let settings = fetch()
        self.cachedSettings = settings
        self.cacheTimestamp = Date()
        return settings
    }

    /// The expected z.ai base URL that indicates z.ai coding plan
    public static let zaiBaseURL = "https://api.z.ai/api/anthropic"

    /// Configuration extracted from Claude's settings.json
    public struct ClaudeSettings: Sendable {
        public let isZaiConfigured: Bool
        public let apiToken: String?
        public let baseURL: String?
        public let timeoutMs: Int?

        public init(isZaiConfigured: Bool, apiToken: String?, baseURL: String?, timeoutMs: Int?) {
            self.isZaiConfigured = isZaiConfigured
            self.apiToken = apiToken
            self.baseURL = baseURL
            self.timeoutMs = timeoutMs
        }
    }

    /// Reads Claude's settings.json file from the default location
    public static func readSettings(
        homeDirectory: String = NSHomeDirectory(),
        fileName: String = ".claude/settings.json") -> ClaudeSettings
    {
        let settingsPath = "\(homeDirectory)/\(fileName)"
        return self.readSettings(atPath: settingsPath)
    }

    /// Reads Claude's settings.json from a specific path
    public static func readSettings(atPath path: String) -> ClaudeSettings {
        self.getCached(path: path) {
            self.readSettingsFromDisk(atPath: path)
        }
    }

    /// Actually reads settings from disk (not cached)
    private static func readSettingsFromDisk(atPath path: String) -> ClaudeSettings {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            self.log.debug("No Claude settings found at \(path)")
            return ClaudeSettings(isZaiConfigured: false, apiToken: nil, baseURL: nil, timeoutMs: nil)
        }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let env = json?["env"] as? [String: String]

            let baseURL = env?["ANTHROPIC_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let apiToken = env?["ANTHROPIC_AUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let timeoutMs = env?["API_TIMEOUT_MS"].flatMap(Int.init)

            let isZaiConfigured = baseURL == self.zaiBaseURL

            if isZaiConfigured {
                self.log.debug("Detected z.ai configuration in Claude settings")
            }

            return ClaudeSettings(
                isZaiConfigured: isZaiConfigured,
                apiToken: apiToken,
                baseURL: baseURL,
                timeoutMs: timeoutMs)
        } catch {
            self.log.error("Failed to parse Claude settings: \(error.localizedDescription)")
            return ClaudeSettings(isZaiConfigured: false, apiToken: nil, baseURL: nil, timeoutMs: nil)
        }
    }

    /// Returns the API token from Claude settings if z.ai is configured
    public static func zaiAPIToken(
        homeDirectory: String = NSHomeDirectory(),
        fileName: String = ".claude/settings.json") -> String?
    {
        let settings = self.readSettings(homeDirectory: homeDirectory, fileName: fileName)
        return settings.isZaiConfigured ? settings.apiToken : nil
    }
}
