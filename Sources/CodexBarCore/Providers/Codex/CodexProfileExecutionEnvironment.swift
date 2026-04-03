import Foundation

public enum CodexProfileExecutionEnvironment {
    public static let authFileOverrideKey = "CODEXBAR_AUTH_FILE_OVERRIDE"

    struct ResolvedEnvironment {
        let environment: [String: String]
        let cleanup: @Sendable () -> Void
    }

    enum Error: LocalizedError {
        case invalidProfilePath

        var errorDescription: String? {
            switch self {
            case .invalidProfilePath:
                "Selected Codex profile is missing or not a regular file."
            }
        }
    }

    static func resolvedEnvironment(
        from base: [String: String],
        fileManager: FileManager = .default) throws -> ResolvedEnvironment
    {
        guard let overridePath = base[authFileOverrideKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !overridePath.isEmpty
        else {
            return ResolvedEnvironment(environment: base, cleanup: {})
        }

        let sourceURL = URL(fileURLWithPath: overridePath)
        guard self.isSafeRegularFile(sourceURL) else {
            throw Error.invalidProfilePath
        }

        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("codexbar-codex-home-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try self.setPermissions(0o700, for: tempDirectory, fileManager: fileManager)

        let destinationURL = tempDirectory.appendingPathComponent("auth.json")
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        try self.setPermissions(0o600, for: destinationURL, fileManager: fileManager)

        var environment = base
        environment["CODEX_HOME"] = tempDirectory.path
        environment.removeValue(forKey: Self.authFileOverrideKey)

        let tempPath = tempDirectory.path
        return ResolvedEnvironment(
            environment: environment,
            cleanup: {
                try? FileManager.default.removeItem(atPath: tempPath)
            })
    }

    private static func isSafeRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func setPermissions(_ permissions: Int16, for url: URL, fileManager: FileManager) throws {
        #if os(macOS)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path)
        #endif
    }
}
