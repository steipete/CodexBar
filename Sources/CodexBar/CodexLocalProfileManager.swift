import AppKit
import CodexBarCore
import Darwin
import Foundation

struct CodexLocalProfileRunningProcesses: Equatable {
    struct CLIProcess: Equatable, Identifiable {
        let id: pid_t
        let command: String
    }

    let codexAppRunning: Bool
    let cliProcesses: [CLIProcess]

    var hasRunningProcesses: Bool {
        self.codexAppRunning || !self.cliProcesses.isEmpty
    }
}

struct CodexLocalProfileSaveResult: Equatable {
    let profile: DiscoveredCodexProfile
}

struct CodexLocalProfileSwitchResult: Equatable {
    let profile: DiscoveredCodexProfile
    let backupURL: URL?
}

enum CodexLocalProfileManagerError: LocalizedError, Equatable {
    case invalidProfileName
    case duplicateProfileName(String)
    case authFileMissing(String)
    case invalidAuthFile(String)
    case invalidProfilePath(String)
    case symlinkNotAllowed(String)
    case runningProcessesFound(CodexLocalProfileRunningProcesses)
    case failedToTerminateCodexApp
    case failedToTerminateCLIProcess(pid_t)
    case codexAppMissing(String)
    case failedToReopenCodexApp(String)

    var errorDescription: String? {
        switch self {
        case .invalidProfileName:
            return "Use only letters, numbers, dot, dash, and underscore in the profile name."
        case let .duplicateProfileName(name):
            return "A saved Codex profile named '\(name)' already exists."
        case let .authFileMissing(path):
            return "No valid live Codex auth file exists at \(path). Log into Codex first."
        case let .invalidAuthFile(path):
            return "Codex auth data is invalid at \(path). Re-authenticate in Codex and try again."
        case let .invalidProfilePath(path):
            return "The saved Codex profile is missing or invalid: \(path)"
        case let .symlinkNotAllowed(path):
            return "CodexBar refuses to use symlinked auth/profile paths: \(path)"
        case let .runningProcessesFound(processes):
            let appText = processes.codexAppRunning ? "Codex.app" : nil
            let cliText = !processes.cliProcesses.isEmpty
                ? "\(processes.cliProcesses.count) codex CLI session" + (processes.cliProcesses.count == 1 ? "" : "s")
                : nil
            let parts = [appText, cliText].compactMap(\.self)
            return "Codex account switching needs exclusive access. Close \(parts.joined(separator: " and ")) first."
        case .failedToTerminateCodexApp:
            return "CodexBar could not close Codex.app."
        case let .failedToTerminateCLIProcess(pid):
            return "CodexBar could not stop codex CLI process \(pid)."
        case let .codexAppMissing(path):
            return "Codex.app was not found at \(path)."
        case let .failedToReopenCodexApp(path):
            return "CodexBar switched the profile, but could not reopen Codex.app from \(path)."
        }
    }
}

@MainActor
protocol CodexLocalProfileRuntimeProtocol {
    func runningProcesses() async throws -> CodexLocalProfileRunningProcesses
    func close(processes: CodexLocalProfileRunningProcesses) async throws
    func reopenCodexApp(at appURL: URL) async throws
}

@MainActor
final class DefaultCodexLocalProfileRuntime: CodexLocalProfileRuntimeProtocol {
    private let workspace: NSWorkspace
    private let runningApplicationsProvider: (String) -> [NSRunningApplication]
    private let psOutputProvider: () throws -> String
    private let waitForCLIExitProvider: ([pid_t]) async -> Set<pid_t>

    init(
        workspace: NSWorkspace = .shared,
        runningApplicationsProvider: @escaping (String) -> [NSRunningApplication] = {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        },
        psOutputProvider: @escaping () throws -> String = {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,comm=,command="]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        },
        waitForCLIExitProvider: @escaping ([pid_t]) async -> Set<pid_t> = DefaultCodexLocalProfileRuntime
            .waitForCLIExit)
    {
        self.workspace = workspace
        self.runningApplicationsProvider = runningApplicationsProvider
        self.psOutputProvider = psOutputProvider
        self.waitForCLIExitProvider = waitForCLIExitProvider
    }

    func runningProcesses() async throws -> CodexLocalProfileRunningProcesses {
        let apps = self.runningApplicationsProvider(CodexLocalProfileManager.codexBundleIdentifier)
            .filter { !$0.isTerminated }
        return try CodexLocalProfileRunningProcesses(
            codexAppRunning: !apps.isEmpty,
            cliProcesses: self.discoverCLIProcesses())
    }

    func close(processes: CodexLocalProfileRunningProcesses) async throws {
        if processes.codexAppRunning {
            let apps = self.runningApplicationsProvider(CodexLocalProfileManager.codexBundleIdentifier)
                .filter { !$0.isTerminated }
            for app in apps {
                _ = app.terminate()
            }
            try await self.waitForAppsToTerminate(apps)
        }

        let cliPIDs = processes.cliProcesses.map(\.id)
        guard !cliPIDs.isEmpty else { return }
        for pid in cliPIDs {
            if kill(pid, SIGTERM) != 0, errno != ESRCH {
                throw CodexLocalProfileManagerError.failedToTerminateCLIProcess(pid)
            }
        }
        let remainingAfterTERM = await self.waitForCLIExitProvider(cliPIDs)
        if !remainingAfterTERM.isEmpty {
            for pid in remainingAfterTERM {
                if kill(pid, SIGKILL) != 0, errno != ESRCH {
                    throw CodexLocalProfileManagerError.failedToTerminateCLIProcess(pid)
                }
            }
            let remainingAfterKILL = await self.waitForCLIExitProvider(Array(remainingAfterTERM))
            if let pid = remainingAfterKILL.min() {
                throw CodexLocalProfileManagerError.failedToTerminateCLIProcess(pid)
            }
        }
    }

    func reopenCodexApp(at appURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw CodexLocalProfileManagerError.codexAppMissing(appURL.path)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.workspace.openApplication(at: appURL, configuration: configuration) { _, error in
                if error != nil {
                    continuation.resume(throwing: CodexLocalProfileManagerError.failedToReopenCodexApp(appURL.path))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func discoverCLIProcesses() throws -> [CodexLocalProfileRunningProcesses.CLIProcess] {
        try self.psOutputProvider()
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> CodexLocalProfileRunningProcesses.CLIProcess? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count >= 3,
                      let pidValue = Int32(parts[0]),
                      parts[1] == "codex"
                else {
                    return nil
                }
                return CodexLocalProfileRunningProcesses.CLIProcess(
                    id: pid_t(pidValue),
                    command: String(parts[2]))
            }
            .sorted { $0.id < $1.id }
    }

    private func waitForAppsToTerminate(_ apps: [NSRunningApplication]) async throws {
        for _ in 0..<20 {
            if apps.allSatisfy(\.isTerminated) {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for app in apps where !app.isTerminated {
            _ = app.forceTerminate()
        }
        for _ in 0..<20 {
            if apps.allSatisfy(\.isTerminated) {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw CodexLocalProfileManagerError.failedToTerminateCodexApp
    }

    private static func waitForCLIExit(_ pids: [pid_t]) async -> Set<pid_t> {
        for _ in 0..<20 {
            let remaining = Set(pids.filter(Self.isProcessRunning))
            if remaining.isEmpty {
                return []
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Set(pids.filter(self.isProcessRunning))
    }

    private static func isProcessRunning(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }
}

@MainActor
final class CodexLocalProfileManager {
    static let codexBundleIdentifier = "com.openai.codex"
    static let codexAppURL = URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)

    private let authFileURL: URL
    private let fileManager: FileManager
    private let runtime: any CodexLocalProfileRuntimeProtocol
    private let appURL: URL

    init(
        authFileURL: URL = CodexOAuthCredentialsStore.authFilePath(),
        fileManager: FileManager = .default,
        runtime: any CodexLocalProfileRuntimeProtocol = DefaultCodexLocalProfileRuntime(),
        appURL: URL = CodexLocalProfileManager.codexAppURL)
    {
        self.authFileURL = authFileURL.standardizedFileURL
        self.fileManager = fileManager
        self.runtime = runtime
        self.appURL = appURL.standardizedFileURL
    }

    func profiles() -> [DiscoveredCodexProfile] {
        CodexProfileStore.displayProfiles(authFileURL: self.authFileURL, fileManager: self.fileManager)
    }

    func runningProcesses() async throws -> CodexLocalProfileRunningProcesses {
        try await self.runtime.runningProcesses()
    }

    func saveCurrentProfile(
        named rawName: String,
        allowClosingRunningProcesses: Bool = false) async throws -> CodexLocalProfileSaveResult
    {
        let profileName = try self.validateProfileName(rawName)
        let processes = try await self.runningProcesses()
        if processes.hasRunningProcesses {
            guard allowClosingRunningProcesses else {
                throw CodexLocalProfileManagerError.runningProcessesFound(processes)
            }
            try await self.runtime.close(processes: processes)
        }

        try self.ensurePrivateDirectory(self.codexDirectoryURL())
        try self.ensurePrivateDirectory(self.profilesDirectoryURL())
        try self.ensurePrivateDirectory(self.backupsDirectoryURL())
        try self.validateAuthFile(at: self.authFileURL)

        let destinationURL = self.profileURL(named: profileName)
        guard self.fileManager.fileExists(atPath: destinationURL.path) == false else {
            throw CodexLocalProfileManagerError.duplicateProfileName(profileName)
        }

        try self.copyAtomically(from: self.authFileURL, to: destinationURL, permissions: 0o600)
        guard let profile = CodexProfileStore.profile(
            at: destinationURL,
            alias: profileName,
            fileManager: self.fileManager)
        else {
            throw CodexLocalProfileManagerError.invalidProfilePath(destinationURL.path)
        }
        return CodexLocalProfileSaveResult(profile: profile)
    }

    func switchToProfile(
        at rawPath: String,
        allowClosingRunningProcesses: Bool = false) async throws -> CodexLocalProfileSwitchResult
    {
        let sourceURL = URL(fileURLWithPath: rawPath, isDirectory: false).standardizedFileURL
        try self.validateAuthFile(at: sourceURL, invalidPathError: .invalidProfilePath(sourceURL.path))

        let processes = try await self.runningProcesses()
        if processes.hasRunningProcesses {
            guard allowClosingRunningProcesses else {
                throw CodexLocalProfileManagerError.runningProcessesFound(processes)
            }
            try await self.runtime.close(processes: processes)
        }

        try self.ensurePrivateDirectory(self.codexDirectoryURL())
        try self.ensurePrivateDirectory(self.profilesDirectoryURL())
        try self.ensurePrivateDirectory(self.backupsDirectoryURL())

        let backupURL: URL?
        if self.fileManager.fileExists(atPath: self.authFileURL.path) {
            try self.validateAuthFile(at: self.authFileURL)
            let timestamp = Self.backupTimestampFormatter.string(from: Date())
            let url = self.backupsDirectoryURL().appendingPathComponent("auth-\(timestamp).json", isDirectory: false)
            try self.copyAtomically(from: self.authFileURL, to: url, permissions: 0o600)
            backupURL = url
        } else {
            backupURL = nil
        }

        try self.copyAtomically(from: sourceURL, to: self.authFileURL, permissions: 0o600)
        try await self.runtime.reopenCodexApp(at: self.appURL)

        let activeProfile = self.profiles().first(where: { $0.isActiveInCodex && $0.fileURL == sourceURL })
            ?? CodexProfileStore.profile(
                at: sourceURL,
                alias: sourceURL.deletingPathExtension().lastPathComponent,
                fileManager: self.fileManager)
        guard let activeProfile else {
            throw CodexLocalProfileManagerError.invalidProfilePath(sourceURL.path)
        }
        return CodexLocalProfileSwitchResult(profile: activeProfile, backupURL: backupURL)
    }

    func profilesDirectoryURL() -> URL {
        self.codexDirectoryURL().appendingPathComponent("profiles", isDirectory: true)
    }

    func backupsDirectoryURL() -> URL {
        self.codexDirectoryURL().appendingPathComponent("auth-backups", isDirectory: true)
    }

    private func codexDirectoryURL() -> URL {
        self.authFileURL.deletingLastPathComponent()
    }

    private func profileURL(named name: String) -> URL {
        self.profilesDirectoryURL().appendingPathComponent("\(name).json", isDirectory: false)
    }

    private func validateProfileName(_ rawName: String) throws -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CodexLocalProfileManagerError.invalidProfileName
        }
        let valid = trimmed.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
        }
        guard valid else {
            throw CodexLocalProfileManagerError.invalidProfileName
        }
        return trimmed
    }

    private func validateAuthFile(
        at url: URL,
        invalidPathError: CodexLocalProfileManagerError? = nil) throws
    {
        if self.fileManager.fileExists(atPath: url.path) == false {
            if let invalidPathError {
                throw invalidPathError
            }
            throw CodexLocalProfileManagerError.authFileMissing(url.path)
        }
        try self.ensureSafeRegularFile(url)
        do {
            _ = try CodexOAuthCredentialsStore.load(from: url)
        } catch {
            if let invalidPathError {
                throw invalidPathError
            }
            throw CodexLocalProfileManagerError.invalidAuthFile(url.path)
        }
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        try self.fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try self.ensureNotSymlink(url)
        try self.setPermissions(0o700, at: url)
    }

    private func ensureSafeRegularFile(_ url: URL) throws {
        try self.ensureNotSymlink(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CodexLocalProfileManagerError.invalidProfilePath(url.path)
        }
    }

    private func ensureNotSymlink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw CodexLocalProfileManagerError.symlinkNotAllowed(url.path)
        }
    }

    private func copyAtomically(from sourceURL: URL, to destinationURL: URL, permissions: Int16) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        try self.fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString)",
            isDirectory: false)
        try self.fileManager.copyItem(at: sourceURL, to: temporaryURL)
        try self.setPermissions(permissions, at: temporaryURL)
        if self.fileManager.fileExists(atPath: destinationURL.path) {
            _ = try self.fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try self.fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        try self.setPermissions(permissions, at: destinationURL)
    }

    private func setPermissions(_ permissions: Int16, at url: URL) throws {
        try self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path)
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}
