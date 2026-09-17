import Foundation

/// A fresh, private, one-shot transaction. No raw log cache survives a successful return.
public struct CodexRemoteLogMirror: Sendable {
    struct Limits: Sendable {
        var totalBytes: Int64 = 512 * 1024 * 1024
        var fileBytes: Int64 = 256 * 1024 * 1024
        var fileCount: Int = 10000
        var seconds: TimeInterval = 300
        var outputBytes: Int = 16 * 1024 * 1024
        var monitorNanoseconds: UInt64 = 50_000_000
    }

    struct Command: Sendable {
        enum Kind: Sendable { case manifest, transfer }
        let kind: Kind
        let binary: String
        let arguments: [String]
        let environment: [String: String]
        let outputBytes: Int
        var lockDescriptor: Int32?
    }

    typealias Runner = @Sendable (Command) async throws -> String
    typealias Removal = @Sendable (URL) throws -> Void
    let environment: [String: String]
    let temporaryRoot: URL
    let limits: Limits
    let runner: Runner
    let remove: Removal

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, temporaryRoot: URL? = nil) {
        self.init(environment: environment, temporaryRoot: temporaryRoot, limits: Limits())
    }

    init(
        environment: [String: String],
        temporaryRoot: URL?,
        limits: Limits,
        runner: @escaping Runner = CodexRemoteLogMirrorProcess.run,
        remove: @escaping Removal = CodexRemoteLogStorage.removeRequest)
    {
        self.environment = environment
        self.temporaryRoot = temporaryRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-ssh-logs", isDirectory: true)
        self.limits = limits
        self.runner = runner
        self.remove = remove
    }

    public func withMirror<T: Sendable>(
        source: CodexRemoteLogSource,
        operation: @escaping @Sendable (CodexRemoteLogSnapshot) async throws -> T) async throws -> T
    {
        try source.validate()
        #if DEBUG
        if let file = self.environment["CODEXBAR_SSH_CONFIG_FILE"],
           !file.hasPrefix("/") || !CodexRemoteLogSource.validHome(file)
        {
            throw CodexRemoteLogError.invalidSource
        }
        #endif
        try Task.checkCancellation()
        let request = try CodexRemoteLogStorage.create(root: self.temporaryRoot)
        let result: Result<T, any Error>
        do {
            let snapshot: CodexRemoteLogSnapshot
            do { snapshot = try await self.collect(source: source, request: request) } catch is CancellationError {
                throw CodexRemoteLogError.cancelled
            } catch let error as CodexRemoteLogError { throw error } catch {
                throw CodexRemoteLogError.localStorage
            }
            try Task.checkCancellation()
            result = try await .success(operation(snapshot))
        } catch { result = .failure(error) }
        // The consumer and all owned subprocesses have returned before deletion starts.
        do { try self.remove(request.url) } catch { throw CodexRemoteLogError.cleanupFailed }
        withExtendedLifetime(request) {}
        if Task.isCancelled { throw CodexRemoteLogError.cancelled }
        return try result.get()
    }

    public func cleanupAbandonedRequests() async throws {
        guard FileManager.default.fileExists(atPath: self.temporaryRoot.path) else { return }
        do { try CodexRemoteLogStorage.privateDirectory(self.temporaryRoot) } catch {
            throw CodexRemoteLogError.cleanupFailed
        }
        let children: [URL]
        do { children = try FileManager.default.contentsOfDirectory(
            at: self.temporaryRoot,
            includingPropertiesForKeys: nil) } catch { throw CodexRemoteLogError.cleanupFailed }
        for child in children {
            guard let request = CodexRemoteLogStorage.abandoned(child) else { continue }
            do { try self.remove(request.url) } catch { throw CodexRemoteLogError.cleanupFailed }
            withExtendedLifetime(request) {}
        }
    }

    private func collect(
        source: CodexRemoteLogSource,
        request ownership: CodexRemoteLogStorage.Request) async throws -> CodexRemoteLogSnapshot
    {
        let request = ownership.url
        let capturedFrom = Date()
        let deadline = ProcessInfo.processInfo.systemUptime + self.limits.seconds
        let staging = request.appendingPathComponent("staging", isDirectory: true)
        let scanCache = request.appendingPathComponent("scan-cache", isDirectory: true)
        try CodexRemoteLogStorage.privateDirectory(staging)
        try CodexRemoteLogStorage.privateDirectory(scanCache)
        let before = try await self.manifest(source: source, deadline: deadline)
        for directory in before.directories.sorted(by: { $0.count < $1.count }) {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexRemoteLogError.timedOut }
            try CodexRemoteLogStorage.privateDirectory(staging.appendingPathComponent(directory, isDirectory: true))
        }
        for root in CodexRemoteLogManifest.rootNames {
            try CodexRemoteLogStorage.privateDirectory(staging.appendingPathComponent(root, isDirectory: true))
        }
        if !before.files.isEmpty {
            let fileList = request.appendingPathComponent("files.list")
            let paths = before.files.keys.sorted().map { $0 + "\0" }.joined()
            try CodexRemoteLogStorage.privateFile(Data(paths.utf8), at: fileList)
            var command = self.transferCommand(
                source: source,
                home: before.home,
                list: fileList,
                staging: staging,
                remainingSeconds: max(1, Int(ceil(deadline - ProcessInfo.processInfo.systemUptime))))
            command.lockDescriptor = ownership.descriptor
            _ = try await self.execute(command, deadline: deadline, watching: staging)
        }
        // Reuse the first resolved absolute home, even if the login environment changes.
        let after = try await self.manifest(
            source: CodexRemoteLogSource(host: source.host, home: before.home), deadline: deadline)
        guard before == after else { throw CodexRemoteLogError.unstableSource }
        let received = try CodexRemoteLogStorage.verifyTree(staging, limits: self.limits)
        guard received.count == before.files.count else { throw CodexRemoteLogError.transferFailed }
        for (path, entry) in before.files {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexRemoteLogError.timedOut }
            guard received[path] == entry.size else { throw CodexRemoteLogError.transferFailed }
            guard try CodexRemoteLogManifest.fileDigest(
                staging.appendingPathComponent(path), deadline: deadline) == entry.sha256
            else {
                throw CodexRemoteLogError.unstableSource
            }
        }
        let ready = request.appendingPathComponent("ready", isDirectory: true)
        do { try FileManager.default.moveItem(at: staging, to: ready) } catch { throw CodexRemoteLogError.localStorage }
        return CodexRemoteLogSnapshot(
            roots: CodexRemoteLogManifest.rootNames.map { ready.appendingPathComponent($0, isDirectory: true) },
            workDirectory: request,
            scanCacheRoot: scanCache,
            capturedFrom: capturedFrom,
            capturedTo: Date())
    }

    private func manifest(source: CodexRemoteLogSource, deadline: TimeInterval) async throws -> CodexRemoteLogManifest {
        let command = Command(
            kind: .manifest,
            binary: "/usr/bin/ssh",
            arguments: self.effectiveSSHArguments + [
                "-n",
                "--",
                source.host,
                CodexRemoteLogManifest.command(
                    home: source.home,
                    limits: self.limits),
            ],
            environment: self.processEnvironment,
            outputBytes: self.limits.outputBytes)
        let output = try await self.execute(command, deadline: deadline)
        return try CodexRemoteLogManifest(output, limits: self.limits)
    }

    static let sshArguments = [
        "-T", "-oBatchMode=yes", "-oConnectTimeout=5", "-oStrictHostKeyChecking=yes",
        "-oNumberOfPasswordPrompts=0", "-oClearAllForwardings=yes", "-oRequestTTY=no",
        "-oForwardAgent=no", "-oForwardX11=no", "-oPermitLocalCommand=no",
        "-oServerAliveInterval=5", "-oServerAliveCountMax=2",
        "-oControlMaster=no", "-oControlPath=none", "-oControlPersist=no",
    ]

    private var effectiveSSHArguments: [String] {
        #if DEBUG
        if let file = self.environment["CODEXBAR_SSH_CONFIG_FILE"], file.hasPrefix("/"),
           CodexRemoteLogSource.validHome(file)
        {
            return Self.sshArguments + ["-F", file]
        }
        #endif
        return Self.sshArguments
    }

    private var processEnvironment: [String: String] {
        var environment = self.environment
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment.removeValue(forKey: "DISPLAY")
        return environment
    }

    func transferCommand(
        source: CodexRemoteLogSource,
        home: String,
        list: URL,
        staging: URL,
        remainingSeconds: Int = 300) -> Command
    {
        // Fixed argv is safe at rsync's second shell boundary. In particular, no -n: rsync needs SSH stdin.
        let remoteShell = (["/usr/bin/ssh"] + self.effectiveSSHArguments).joined(separator: " ")
        // Explicitly remove group/other bits: macOS openrsync does not clear them for empty
        // assignments such as Dgo= or Fgo=. Keep receiving files private, including temporary files.
        let arguments = [
            "--relative", "--no-implied-dirs", "--perms", "--chmod=Du=rwx,Dgo-rwx,Fu=rw,Fgo-rwx",
            "-0", "--files-from=" + list.path, "--max-size=\(self.limits.fileBytes)",
            "--bwlimit=4096", "--timeout=15", "-e", remoteShell,
            "--", source.host + ":" + home + "/", staging.path + "/",
        ]
        return Command(
            kind: .transfer,
            binary: CodexRemoteLogGuardian.executable(environment: self.environment),
            arguments: [
                CodexRemoteLogGuardian.argument,
                String(max(1, min(300, remainingSeconds))),
                String(self.limits.fileBytes),
                String(self.limits.totalBytes),
                String(self.limits.fileCount),
                "--",
            ] + arguments,
            environment: self.processEnvironment,
            outputBytes: 64 * 1024)
    }

    private func execute(_ command: Command, deadline: TimeInterval, watching: URL? = nil) async throws -> String {
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await self.runner(command) }
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        guard ProcessInfo.processInfo.systemUptime < deadline
                        else { throw CodexRemoteLogError.timedOut }
                        if let watching { _ = try CodexRemoteLogStorage.verifyTree(watching, limits: self.limits) }
                        try await Task.sleep(nanoseconds: self.limits.monitorNanoseconds)
                    }
                }
                defer { group.cancelAll() }
                guard let output = try await group.next() else { throw CodexRemoteLogError.transferFailed }
                return output
            }
        } catch is CancellationError { throw CodexRemoteLogError.cancelled } catch let error as CodexRemoteLogError {
            throw error
        } catch {
            throw command.kind == .transfer ? CodexRemoteLogError.transferFailed : .remoteUnavailable
        }
    }
}
