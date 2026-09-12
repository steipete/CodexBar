import Foundation

/// Codex-owned test isolation. Credential environments select paths; they never authorize them.
public enum CodexCredentialFileAccess {
    public static let isolationEnvironmentKey = "CODEXBAR_TEST_CODEX_FILE_ISOLATION"
    private static let fixtureEnvironmentKey = "CODEXBAR_TEST_CODEX_FILE_FIXTURES"

    public struct FixtureScope: Codable, Sendable {
        private struct Grant: Codable, Sendable {
            let url: URL
            let resolvedURL: URL
            let isRoot: Bool
        }

        private let grants: [Grant]

        public init(files: [URL] = [], roots: [URL] = []) {
            self.grants = files.map { Grant(
                url: $0.standardizedFileURL,
                resolvedURL: CodexCredentialFileAccess.resolve($0.deletingLastPathComponent())
                    .appendingPathComponent($0.lastPathComponent),
                isRoot: false) } + roots.map { Grant(
                url: $0.standardizedFileURL,
                resolvedURL: CodexCredentialFileAccess.resolve($0.deletingLastPathComponent())
                    .appendingPathComponent($0.lastPathComponent),
                isRoot: true) }
        }

        fileprivate func permits(_ url: URL) -> Bool {
            let candidate = url.standardizedFileURL
            // Reject unregistered targets before even resolving symlinks (a metadata operation).
            return self.grants.contains { grant in
                guard Self.contains(candidate, in: grant.url, isRoot: grant.isRoot) else { return false }
                // Foundation may leave dangling symlinks unresolved. Inspect each fixture component
                // before resolving or opening it, including destinations that do not exist yet.
                var component = grant.url
                guard CodexCredentialFileAccess.isNonSymlink(component) else { return false }
                for name in candidate.pathComponents.dropFirst(grant.url.pathComponents.count) {
                    component.appendPathComponent(name)
                    guard CodexCredentialFileAccess.isNonSymlink(component) else { return false }
                }
                guard CodexCredentialFileAccess.resolve(grant.url).path == grant.resolvedURL.path else {
                    return false
                }
                return true
            }
        }

        func including(root: URL) -> Self {
            Self(grants: self.grants + Self(roots: [root]).grants)
        }

        private init(grants: [Grant]) {
            self.grants = grants
        }

        private static func contains(_ url: URL, in parent: URL, isRoot: Bool) -> Bool {
            guard url.isFileURL, parent.isFileURL else { return false }
            if !isRoot { return url.pathComponents == parent.pathComponents }
            return url.pathComponents.starts(with: parent.pathComponents)
        }

        /// Supply only this child's fixtures; never copy a parent's fixture authorization.
        public func childEnvironment(base: [String: String]) throws -> [String: String] {
            var environment = base
            environment[CodexCredentialFileAccess.isolationEnvironmentKey] = "1"
            try environment[CodexCredentialFileAccess.fixtureEnvironmentKey] =
                String(data: JSONEncoder().encode(self), encoding: .utf8)
            return environment
        }
    }

    @TaskLocal public static var fixtureScope: FixtureScope?

    public static var isTestContext: Bool {
        self.isTestContext(
            processName: ProcessInfo.processInfo.processName,
            environment: ProcessInfo.processInfo.environment)
    }

    static func isTestContext(processName: String, environment: [String: String]) -> Bool {
        environment[self.isolationEnvironmentKey] == "1"
            || KeychainTestSafety.isRunningUnderTests(processName: processName, environment: environment)
    }

    public static func permits(_ url: URL) -> Bool {
        guard self.isTestContext else { return true }
        if let fixtureScope { return fixtureScope.permits(url) }
        let environment = ProcessInfo.processInfo.environment
        guard let encoded = environment[self.fixtureEnvironmentKey]?.data(using: .utf8),
              let scope = try? JSONDecoder().decode(FixtureScope.self, from: encoded)
        else { return false }
        return scope.permits(url)
    }

    public static func withFixtureScope<T>(_ scope: FixtureScope?, operation: () throws -> T) rethrows -> T {
        try self.$fixtureScope.withValue(scope, operation: operation)
    }

    public static func withFixtureScope<T>(
        _ scope: FixtureScope?,
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$fixtureScope.withValue(scope) {
            try await operation()
        }
    }

    /// Small substitution seam for boundary tests; never changes authorization.
    public enum Operation: Sendable { case read, existence, metadata, directory, write }
    #if DEBUG
    @TaskLocal public static var testIO: (@Sendable (Operation, URL) throws -> Data)?
    #endif

    private static func resolve(_ url: URL) -> URL {
        #if DEBUG
        if let testIO {
            guard let data = try? testIO(.metadata, url),
                  let path = String(data: data, encoding: .utf8)
            else { return URL(fileURLWithPath: "/") }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        #endif
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isNonSymlink(_ url: URL) -> Bool {
        #if DEBUG
        if let testIO { return (try? testIO(.metadata, url)) != nil }
        #endif
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.type] as? FileAttributeType != .typeSymbolicLink
        } catch {
            let error = error as NSError
            let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
            // A missing child (including a regular-file parent) cannot be a symlink. Let the
            // existing reader/writer classify that fixture error instead of masking it as denial.
            return (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoSuchFile.rawValue)
                || (underlying.domain == NSPOSIXErrorDomain
                    && [POSIXErrorCode.ENOENT.rawValue, POSIXErrorCode.ENOTDIR.rawValue]
                    .contains(Int32(underlying.code)))
        }
    }

    public static func read(at url: URL, options: Data.ReadingOptions = []) throws -> Data {
        guard self.permits(url) else { throw CodexOAuthCredentialsError.notFound }
        #if DEBUG
        if let testIO { return try testIO(.read, url) }
        #endif
        return try Data(contentsOf: url, options: options)
    }

    public static func fileExists(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard self.permits(url) else { return false }
        #if DEBUG
        if let testIO { return (try? testIO(.existence, url)) != nil }
        #endif
        return fileManager.fileExists(atPath: url.path)
    }

    public static func createDirectory(forCredentialAt url: URL) throws {
        guard self.permits(url) else { throw CodexOAuthCredentialsError.notFound }
        let directory = url.deletingLastPathComponent()
        #if DEBUG
        if let testIO {
            _ = try testIO(.directory, directory)
            return
        }
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Called after authorization, before the complete read/modify/publish operation.
    public static func substituteWriteForTesting(at url: URL) throws -> Bool {
        #if DEBUG
        guard let testIO else { return false }
        _ = try testIO(.write, url)
        return true
        #else
        return false
        #endif
    }
}
