import Foundation

public struct CodexOpenAIWorkspaceIdentityCache: @unchecked Sendable {
    public static let currentVersion = 1

    private struct Payload: Codable {
        let version: Int
        var labelsByWorkspaceAccountID: [String: String]

        init(
            version: Int = CodexOpenAIWorkspaceIdentityCache.currentVersion,
            labelsByWorkspaceAccountID: [String: String])
        {
            self.version = version
            self.labelsByWorkspaceAccountID = labelsByWorkspaceAccountID
        }
    }

    #if DEBUG
    @TaskLocal static var taskFileURLOverride: URL?
    #endif

    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func workspaceLabel(for workspaceAccountID: String?) -> String? {
        guard let normalizedWorkspaceAccountID = CodexOpenAIWorkspaceResolver
            .normalizeWorkspaceAccountID(workspaceAccountID)
        else {
            return nil
        }

        return self.loadPayload().labelsByWorkspaceAccountID[normalizedWorkspaceAccountID]
    }

    public func store(_ identity: CodexOpenAIWorkspaceIdentity) throws {
        guard let workspaceLabel = CodexOpenAIWorkspaceIdentity.normalizeWorkspaceLabel(identity.workspaceLabel) else {
            return
        }

        var payload = self.loadPayload()
        payload.labelsByWorkspaceAccountID[identity.workspaceAccountID] = workspaceLabel

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        let directory = self.fileURL.deletingLastPathComponent()
        if !self.fileManager.fileExists(atPath: directory.path) {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: self.fileURL, options: [.atomic])
        try self.applySecurePermissionsIfNeeded()
    }

    private func loadPayload() -> Payload {
        guard self.fileManager.fileExists(atPath: self.fileURL.path),
              let data = try? Data(contentsOf: self.fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.currentVersion
        else {
            return Payload(labelsByWorkspaceAccountID: [:])
        }

        return payload
    }

    private func applySecurePermissionsIfNeeded() throws {
        #if os(macOS)
        try self.fileManager.setAttributes([
            .posixPermissions: NSNumber(value: Int16(0o600)),
        ], ofItemAtPath: self.fileURL.path)
        #endif
    }

    public static func defaultURL() -> URL {
        #if DEBUG
        if let override = self.taskFileURLOverride {
            return override
        }
        #endif

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("codex-openai-workspaces.json")
    }
}

#if DEBUG
extension CodexOpenAIWorkspaceIdentityCache {
    public static func withFileURLOverrideForTesting<T>(
        _ fileURL: URL,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskFileURLOverride.withValue(fileURL) {
            try operation()
        }
    }

    public static func withFileURLOverrideForTesting<T>(
        _ fileURL: URL,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskFileURLOverride.withValue(fileURL) {
            try await operation()
        }
    }
}
#endif
