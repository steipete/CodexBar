#if canImport(JavaScriptCore)
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@preconcurrency import JavaScriptCore

public struct ProviderPluginApprovalBinding: Codable, Equatable, Sendable {
    public let instanceID: ProviderInstanceID
    public let origins: [String]
    public let authMode: String
    public let authHeader: String?
    public let secretNames: [String]
    public let capabilities: [String]
    public let cookieDomains: [String]

    public init(manifest: ProviderPluginManifest, settings: [String: String]) throws {
        var origins: Set<String> = []
        for endpoint in manifest.endpoints {
            switch endpoint {
            case let .fixed(origin):
                origins.insert(origin)
            case let .setting(key, policy):
                guard let rawValue = settings[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawValue.isEmpty,
                      let url = URL(string: rawValue)
                else {
                    throw ProviderPluginError.invalidManifest(
                        "endpoint setting '\(key)' must contain a valid URL before approval")
                }
                try origins.insert(ProviderPluginOrigin.normalizedOrigin(of: url, policy: policy))
            }
        }
        if manifest.auth != nil, origins.contains(where: { $0.hasPrefix("http://") }) {
            throw ProviderPluginError.networkPolicy("authenticated plugin origins must use HTTPS")
        }

        self.instanceID = manifest.id
        self.origins = origins.sorted()
        self.authMode = manifest.auth?.type.rawValue ?? "none"
        self.authHeader = manifest.auth?.header
        self.secretNames = manifest.settings.filter { $0.kind == .secure }.map(\.key).sorted()
        self.capabilities = manifest.capabilities.map(\.rawValue).sorted()
        self.cookieDomains = manifest.cookieDomains.sorted()
    }

    public var typedConfirmationOrigins: [String] {
        self.origins.filter(Self.requiresTypedConfirmation)
    }

    private static func requiresTypedConfirmation(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host?.lowercased() else { return true }
        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }
        if self.isIPv4Literal(host) || host.contains(":") {
            return true
        }
        return false
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part).map { (0...255).contains($0) } == true
        }
    }
}

public final class ProviderPluginApprovalStore: @unchecked Sendable {
    private struct Payload: Codable {
        var approvals: [String: ProviderPluginApprovalBinding]
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexBar/plugin-approvals.json")
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL = ProviderPluginApprovalStore.defaultURL) {
        self.fileURL = fileURL
    }

    public func isApproved(_ binding: ProviderPluginApprovalBinding) -> Bool {
        self.lock.withLock { self.load()[binding.instanceID.rawValue] == binding }
    }

    public func record(_ binding: ProviderPluginApprovalBinding) throws {
        try self.lock.withLock {
            var approvals = self.load()
            approvals[binding.instanceID.rawValue] = binding
            try self.save(approvals)
        }
    }

    public func remove(instanceID: ProviderInstanceID) throws {
        try self.lock.withLock {
            var approvals = self.load()
            approvals[instanceID.rawValue] = nil
            try self.save(approvals)
        }
    }

    private func load() -> [String: ProviderPluginApprovalBinding] {
        guard let data = try? Data(contentsOf: self.fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return [:] }
        return payload.approvals
    }

    private func save(_ approvals: [String: ProviderPluginApprovalBinding]) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Payload(approvals: approvals))
        try data.write(to: self.fileURL, options: .atomic)
    }
}

public struct UserProviderPlugin: @unchecked Sendable {
    public static let maximumSourceBytes = 1024 * 1024

    public let fileURL: URL
    public let sourceHash: String
    public let transpiledCacheURL: URL?
    public let transpileCacheHit: Bool
    public let runtime: ProviderPluginRuntime

    public var manifest: ProviderPluginManifest {
        self.runtime.manifest
    }

    public func approvalBinding(settings: [String: String]) throws -> ProviderPluginApprovalBinding {
        try ProviderPluginApprovalBinding(manifest: self.manifest, settings: settings)
    }

    public func fetchUsage(
        settings: [String: String],
        secrets: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        approvalStore: ProviderPluginApprovalStore,
        now: Date = Date(),
        cookieResolver: ProviderPluginRuntime.CookieResolver? = nil,
        instanceCookieResolver: ProviderPluginRuntime.InstanceCookieResolver? = nil) async throws -> UsageSnapshot
    {
        let binding = try self.approvalBinding(settings: settings)
        guard approvalStore.isApproved(binding) else {
            throw UserProviderPluginError.approvalRequired(binding)
        }
        let resolvedSecrets = Self.applyingEnvironmentOverrides(
            secrets: secrets,
            manifest: self.manifest,
            environment: environment)
        return try await self.runtime.fetchUsage(
            settings: settings,
            secrets: resolvedSecrets,
            now: now,
            cookieResolver: cookieResolver,
            instanceCookieResolver: instanceCookieResolver)
    }

    public static func environmentKey(instanceID: ProviderInstanceID, settingKey: String) -> String {
        let id = instanceID.rawValue.uppercased().replacingOccurrences(of: "-", with: "_")
        let key = settingKey.uppercased().map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "_"
        }
        return "CODEXBAR_PLUGIN_\(id)_\(String(key))"
    }

    private static func applyingEnvironmentOverrides(
        secrets: [String: String],
        manifest: ProviderPluginManifest,
        environment: [String: String]) -> [String: String]
    {
        var resolved = secrets
        for setting in manifest.settings where setting.kind == .secure {
            let key = self.environmentKey(instanceID: manifest.id, settingKey: setting.key)
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                resolved[setting.key] = value
            }
        }
        return resolved
    }
}

public enum UserProviderPluginError: LocalizedError, Sendable, Equatable {
    case approvalRequired(ProviderPluginApprovalBinding)

    public var errorDescription: String? {
        switch self {
        case let .approvalRequired(binding):
            "Provider plugin '\(binding.instanceID.rawValue)' needs approval before network access"
        }
    }
}

public struct UserProviderPluginLoadResult: Sendable {
    public let fileURL: URL
    public let plugin: UserProviderPlugin?
    public let error: String?

    public var instanceID: ProviderInstanceID? {
        self.plugin?.manifest.id
    }
}

public final class UserProviderPluginLoader: @unchecked Sendable {
    public static let sucraseVersion = "3.35.1"

    public static var defaultProvidersDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/codexbar/providers", isDirectory: true)
    }

    public static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/CodexBar/plugins", isDirectory: true)
    }

    private let providersDirectory: URL
    private let cacheDirectory: URL
    private let transport: any ProviderHTTPTransport

    public init(
        providersDirectory: URL = UserProviderPluginLoader.defaultProvidersDirectory,
        cacheDirectory: URL = UserProviderPluginLoader.defaultCacheDirectory,
        transport: (any ProviderHTTPTransport)? = nil)
    {
        self.providersDirectory = providersDirectory
        self.cacheDirectory = cacheDirectory
        self.transport = transport ?? UserProviderPluginHTTPTransport.make()
    }

    public func discover() -> [UserProviderPluginLoadResult] {
        let urls: [URL]
        do {
            try FileManager.default.createDirectory(at: self.providersDirectory, withIntermediateDirectories: true)
            urls = try FileManager.default.contentsOfDirectory(
                at: self.providersDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
                .filter { ["js", "ts"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            return [UserProviderPluginLoadResult(
                fileURL: self.providersDirectory,
                plugin: nil,
                error: "Could not scan plugins directory: \(error.localizedDescription)")]
        }

        var seen = Set(UsageProvider.allCases.map(\.instanceID))
        return urls.map { url in
            do {
                let plugin = try self.load(fileURL: url)
                guard seen.insert(plugin.manifest.id).inserted else {
                    throw ProviderPluginError.invalidManifest(
                        "provider id '\(plugin.manifest.id.rawValue)' collides with another provider")
                }
                return UserProviderPluginLoadResult(fileURL: url, plugin: plugin, error: nil)
            } catch {
                return UserProviderPluginLoadResult(fileURL: url, plugin: nil, error: error.localizedDescription)
            }
        }
    }

    public func load(fileURL: URL) throws -> UserProviderPlugin {
        guard ["js", "ts"].contains(fileURL.pathExtension.lowercased()) else {
            throw ProviderPluginError.load("plugin must use a .js or .ts extension")
        }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw ProviderPluginError.load("plugin path is not a regular file")
        }
        guard let size = values.fileSize, size <= UserProviderPlugin.maximumSourceBytes else {
            throw ProviderPluginError.load("plugin exceeds the 1 MiB source limit")
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= UserProviderPlugin.maximumSourceBytes else {
            throw ProviderPluginError.load("plugin exceeds the 1 MiB source limit")
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw ProviderPluginError.load("plugin source is not valid UTF-8")
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let output: (source: String, cacheURL: URL?, cacheHit: Bool) = if fileURL.pathExtension.lowercased() == "ts" {
            try self.transpile(source: source, hash: hash, sourceFileURL: fileURL)
        } else {
            (source, nil, false)
        }
        let runtime = try ProviderPluginRuntime(
            source: output.source,
            transport: self.transport,
            responseSizeLimit: UserProviderPlugin.maximumSourceBytes,
            rejectsNonSuccessResponses: true,
            allowsDynamicID: true)
        return UserProviderPlugin(
            fileURL: fileURL,
            sourceHash: hash,
            transpiledCacheURL: output.cacheURL,
            transpileCacheHit: output.cacheHit,
            runtime: runtime)
    }

    public func install(fileURL: URL) throws -> UserProviderPlugin {
        let validated = try self.load(fileURL: fileURL)
        guard validated.manifest.id.firstPartyProvider == nil,
              UserProviderPluginRegistry.plugin(for: validated.manifest.id) == nil
        else {
            throw ProviderPluginError.invalidManifest(
                "provider id '\(validated.manifest.id.rawValue)' collides with another provider")
        }
        try FileManager.default.createDirectory(at: self.providersDirectory, withIntermediateDirectories: true)
        let destination = self.providersDirectory.appendingPathComponent(fileURL.lastPathComponent)
        guard destination.standardizedFileURL != fileURL.standardizedFileURL else { return validated }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProviderPluginError.load("a plugin named '\(destination.lastPathComponent)' is already installed")
        }
        try FileManager.default.copyItem(at: fileURL, to: destination)
        return try self.load(fileURL: destination)
    }

    private func transpile(
        source: String,
        hash: String,
        sourceFileURL: URL) throws -> (String, URL?, Bool)
    {
        try FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        let sourceName = sourceFileURL.deletingPathExtension().lastPathComponent
        let cacheURL = self.cacheDirectory
            .appendingPathComponent("\(sourceName)-\(hash)-sucrase-\(Self.sucraseVersion).js")
        if let cached = try? String(contentsOf: cacheURL, encoding: .utf8) {
            return (cached, cacheURL, true)
        }
        guard let resourceURL = Bundle.module.url(
            forResource: "sucrase-\(Self.sucraseVersion).min",
            withExtension: "js")
        else {
            throw ProviderPluginError.load("bundled Sucrase \(Self.sucraseVersion) resource was not found")
        }
        guard let context = JSContext() else {
            throw ProviderPluginError.load("JavaScriptCore could not create a TypeScript transpiler context")
        }
        let sucraseSource = try String(contentsOf: resourceURL, encoding: .utf8)
        context.exception = nil
        _ = context.evaluateScript(sucraseSource)
        if let exception = context.exception {
            throw ProviderPluginError.load("Sucrase failed to initialize: \(exception.toString() ?? "unknown error")")
        }
        context.setObject(source, forKeyedSubscript: "__codexbarTypeScriptSource" as NSString)
        context.exception = nil
        let result = context.evaluateScript(
            "sucrase.transform(__codexbarTypeScriptSource, {transforms:['typescript']}).code")
        if let exception = context.exception {
            throw ProviderPluginError
                .load("TypeScript transpilation failed: \(exception.toString() ?? "unknown error")")
        }
        guard let output = result?.toString(), !output.isEmpty else {
            throw ProviderPluginError.load("TypeScript transpilation returned no output")
        }
        try Data(output.utf8).write(to: cacheURL, options: .atomic)
        return (output, cacheURL, false)
    }
}

public enum UserProviderPluginRegistry {
    private final class Store: @unchecked Sendable {
        var results: [UserProviderPluginLoadResult] = []
        var byID: [ProviderInstanceID: UserProviderPlugin] = [:]
    }

    private static let lock = NSLock()
    private static let store = Store()

    @discardableResult
    public static func refresh(loader: UserProviderPluginLoader = UserProviderPluginLoader())
        -> [UserProviderPluginLoadResult]
    {
        let results = loader.discover()
        self.lock.withLock {
            self.store.results = results
            self.store.byID = Dictionary(uniqueKeysWithValues: results.compactMap { result in
                result.plugin.map { ($0.manifest.id, $0) }
            })
        }
        return results
    }

    public static var allResults: [UserProviderPluginLoadResult] {
        self.lock.withLock { self.store.results }
    }

    public static var all: [UserProviderPlugin] {
        self.lock.withLock { self.store.results.compactMap(\.plugin) }
    }

    public static func plugin(for instanceID: ProviderInstanceID) -> UserProviderPlugin? {
        self.lock.withLock { self.store.byID[instanceID] }
    }
}

public enum UserProviderPluginManager {
    public static func delete(
        _ plugin: UserProviderPlugin,
        approvalStore: ProviderPluginApprovalStore,
        config: inout CodexBarConfig,
        historyDirectory: URL? = nil) throws
    {
        if FileManager.default.fileExists(atPath: plugin.fileURL.path) {
            try FileManager.default.removeItem(at: plugin.fileURL)
        }
        let directory = plugin.transpiledCacheURL?.deletingLastPathComponent()
            ?? UserProviderPluginLoader.defaultCacheDirectory
        if FileManager.default.fileExists(atPath: directory.path) {
            let prefix = plugin.fileURL.deletingPathExtension().lastPathComponent + "-"
            let artifacts = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey])
                .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "js" }
            for artifact in artifacts {
                try FileManager.default.removeItem(at: artifact)
            }
        }
        try approvalStore.remove(instanceID: plugin.manifest.id)
        config.providers.removeAll { $0.id == plugin.manifest.id }
        if let historyDirectory {
            let historyURL = historyDirectory.appendingPathComponent("\(plugin.manifest.id.rawValue).json")
            if FileManager.default.fileExists(atPath: historyURL.path) {
                try FileManager.default.removeItem(at: historyURL)
            }
        }
    }
}

private enum UserProviderPluginHTTPTransport {
    static func make() -> any ProviderHTTPTransport {
        UserProviderPluginHTTPClient(maximumResponseBytes: UserProviderPlugin.maximumSourceBytes)
    }
}

private final class UserProviderPluginHTTPClient: NSObject, ProviderHTTPTransport, URLSessionDataDelegate,
    @unchecked Sendable
{
    private struct RequestState {
        var data = Data()
        var response: URLResponse?
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
    }

    private let maximumResponseBytes: Int
    private let lock = NSLock()
    private var states: [Int: RequestState] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.session.dataTask(with: request)
            self.lock.withLock {
                self.states[task.taskIdentifier] = RequestState(continuation: continuation)
            }
            task.resume()
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
    {
        self.lock.withLock { self.states[dataTask.taskIdentifier]?.response = response }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = self.lock.withLock {
            guard var state = self.states[dataTask.taskIdentifier] else { return false }
            guard state.data.count + data.count <= self.maximumResponseBytes else { return true }
            state.data.append(data)
            self.states[dataTask.taskIdentifier] = state
            return false
        }
        guard exceeded else { return }
        dataTask.cancel()
        self.finish(
            taskIdentifier: dataTask.taskIdentifier,
            result: .failure(ProviderPluginError.http("response exceeded the 1048576-byte limit")))
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            self.finish(taskIdentifier: task.taskIdentifier, result: .failure(error))
            return
        }
        let result: Result<(Data, URLResponse), Error> = self.lock.withLock {
            guard let state = self.states[task.taskIdentifier], let response = state.response else {
                return .failure(URLError(.badServerResponse))
            }
            return .success((state.data, response))
        }
        self.finish(taskIdentifier: task.taskIdentifier, result: result)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func finish(taskIdentifier: Int, result: Result<(Data, URLResponse), Error>) {
        let continuation = self.lock.withLock { self.states.removeValue(forKey: taskIdentifier)?.continuation }
        continuation?.resume(with: result)
    }
}
#endif
