#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

public enum ProviderVersionDetector {
    private struct ClaudeExecutableFingerprint: Equatable, Hashable {
        let realPath: String
        let modificationDate: Date
        let fileSize: UInt64
        let inode: UInt64
    }

    private struct ClaudeVersionCacheEntry {
        let fingerprint: ClaudeExecutableFingerprint
        let version: String
        let cachedAt: Date
    }

    private final class PendingDetection {
        let group = DispatchGroup()
        var result: String?
    }

    static let claudeVersionCacheTTL: TimeInterval = 30 * 60
    private static let lock = NSLock()
    private nonisolated(unsafe) static var claudeVersionCache: ClaudeVersionCacheEntry?
    private nonisolated(unsafe) static var claudePendingDetections: [ClaudeExecutableFingerprint: PendingDetection] =
        [:]

    #if DEBUG
    public nonisolated(unsafe) static var whichHook: ((String) -> String?)?
    public nonisolated(unsafe) static var attributesHook: ((String) -> [FileAttributeKey: Any]?)?
    public nonisolated(unsafe) static var runClaudeVersionHook: ((String) throws -> TTYCommandRunner.Result?)?
    public nonisolated(unsafe) static var nowHook: (() -> Date)?

    public static func resetHooksAndCache() {
        self.lock.lock()
        self.claudeVersionCache = nil
        self.claudePendingDetections.removeAll()
        self.whichHook = nil
        self.attributesHook = nil
        self.runClaudeVersionHook = nil
        self.nowHook = nil
        self.lock.unlock()
    }
    #endif

    private static func currentDate() -> Date {
        #if DEBUG
        return self.nowHook?() ?? Date()
        #else
        return Date()
        #endif
    }

    private static func resolveRealPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil {
            return buffer.withUnsafeBufferPointer { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return path }
                return String(cString: baseAddress)
            }
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func getClaudeFingerprint(forPath path: String) -> ClaudeExecutableFingerprint? {
        let resolvedPath = self.resolveRealPath(path)
        #if DEBUG
        let attributesOpt = self.attributesHook != nil ? self.attributesHook?(resolvedPath) : try? FileManager.default
            .attributesOfItem(atPath: resolvedPath)
        #else
        let attributesOpt = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
        #endif
        guard let attributes = attributesOpt else {
            return nil
        }
        guard let modificationDate = attributes[.modificationDate] as? Date,
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            return nil
        }
        return ClaudeExecutableFingerprint(
            realPath: resolvedPath,
            modificationDate: modificationDate,
            fileSize: fileSize,
            inode: inode)
    }

    private static func runClaudeVersionCommand(path: String) -> String? {
        let commandResult: TTYCommandRunner.Result?
        #if DEBUG
        if let hook = runClaudeVersionHook {
            do {
                commandResult = try hook(path)
            } catch {
                commandResult = nil
            }
        } else {
            do {
                commandResult = try TTYCommandRunner().run(
                    binary: path,
                    send: "",
                    options: TTYCommandRunner.Options(
                        timeout: 5.0,
                        extraArgs: ["--version"],
                        initialDelay: 0.0,
                        useClaudeProbeWorkingDirectory: true))
            } catch {
                commandResult = nil
            }
        }
        #else
        do {
            commandResult = try TTYCommandRunner().run(
                binary: path,
                send: "",
                options: TTYCommandRunner.Options(
                    timeout: 5.0,
                    extraArgs: ["--version"],
                    initialDelay: 0.0,
                    useClaudeProbeWorkingDirectory: true))
        } catch {
            commandResult = nil
        }
        #endif

        guard let commandResult,
              commandResult.completion == .processExited(status: 0)
        else { return nil }
        let trimmed = TextParsing.stripANSICodes(commandResult.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func claudeVersion() -> String? {
        #if DEBUG
        let pathOpt = self.whichHook != nil ? self.whichHook!("claude") : TTYCommandRunner.which("claude")
        #else
        let pathOpt = TTYCommandRunner.which("claude")
        #endif
        guard let path = pathOpt else { return nil }

        guard let fingerprint = getClaudeFingerprint(forPath: path) else {
            return self.runClaudeVersionCommand(path: path)
        }
        self.lock.lock()
        let now = self.currentDate()
        let cacheAge = self.claudeVersionCache.map { now.timeIntervalSince($0.cachedAt) }
        if let cached = claudeVersionCache,
           cached.fingerprint == fingerprint,
           let cacheAge,
           cacheAge >= 0,
           cacheAge < self.claudeVersionCacheTTL
        {
            self.lock.unlock()
            return cached.version
        }
        self.claudeVersionCache = nil

        if let pending = claudePendingDetections[fingerprint] {
            self.lock.unlock()
            pending.group.wait()
            self.lock.lock()
            let result = pending.result
            self.lock.unlock()
            return result
        }

        let pending = PendingDetection()
        pending.group.enter()
        self.claudePendingDetections[fingerprint] = pending
        self.lock.unlock()

        let result = self.runClaudeVersionCommand(path: path)
        let completedAt = self.currentDate()

        self.lock.lock()
        pending.result = result
        if let version = result {
            self.claudeVersionCache = ClaudeVersionCacheEntry(
                fingerprint: fingerprint,
                version: version,
                cachedAt: completedAt)
        }
        self.claudePendingDetections.removeValue(forKey: fingerprint)
        pending.group.leave()
        self.lock.unlock()

        return result
    }

    public static func codexVersion() -> String? {
        guard let path = TTYCommandRunner.which("codex") else { return nil }
        let candidates = [
            ["--version"],
            ["version"],
            ["-v"],
        ]
        for args in candidates {
            if let version = Self.run(path: path, args: args) {
                return version
            }
        }
        return nil
    }

    public static func geminiVersion() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let path = BinaryLocator.resolveGeminiBinary(env: env, loginPATH: nil)
            ?? TTYCommandRunner.which("gemini") else { return nil }
        let candidates = [
            ["--version"],
            ["-v"],
        ]
        for args in candidates {
            if let version = Self.run(path: path, args: args) {
                return version
            }
        }
        return nil
    }

    static func run(
        path: String,
        args: [String],
        timeout: TimeInterval = 2.0,
        environment: [String: String]? = nil,
        mergeStandardError: Bool = false) -> String?
    {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.environment = environment
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = mergeStandardError ? out : FileHandle.nullDevice
        proc.standardInput = nil
        let outputCapture = ProcessPipeCapture(pipe: out)
        outputCapture.start()

        let exitSemaphore = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in
            exitSemaphore.signal()
        }

        do {
            try proc.run()
        } catch {
            outputCapture.stop()
            return nil
        }

        let didExit = exitSemaphore.wait(timeout: .now() + timeout) == .success
        if !didExit, !Self.forceExit(proc, exitSemaphore: exitSemaphore) {
            outputCapture.stop()
            return nil
        }

        let data = outputCapture.finishSynchronously(timeout: 0.25)
        guard proc.terminationStatus == 0,
              let text = ProcessPipeCapture.decodeUTF8(data)
                  .split(whereSeparator: \.isNewline).first
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func forceExit(_ proc: Process, exitSemaphore: DispatchSemaphore) -> Bool {
        guard proc.isRunning else { return true }

        proc.terminate()
        if exitSemaphore.wait(timeout: .now() + 0.5) == .success {
            return true
        }

        guard proc.isRunning else { return true }
        kill(proc.processIdentifier, SIGKILL)
        return exitSemaphore.wait(timeout: .now() + 1.0) == .success
    }
}
