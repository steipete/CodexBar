#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import CodexBarCore
import Foundation

@main
enum CodexBarLinuxMain {
    static func main() async {
        do {
            let options = try LinuxDashboardOptions.parse(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.showHelp {
                Self.printHelp()
                exit(0)
            }

            let app = LinuxDashboardApp(options: options)
            try await app.run()
            exit(0)
        } catch {
            fputs("CodexBarLinux error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func printHelp() {
        print(
            """
            CodexBarLinux - lightweight Ubuntu dashboard for CodexBarCLI

            Usage:
              CodexBarLinux [launch|serve|refresh|open|stop] [options]

            Commands:
              launch   Render once, start the background refresher, and open the dashboard
              serve    Run the refresher loop in the foreground
              refresh  Fetch once and rewrite the dashboard files
              open     Open the generated dashboard in the default browser
              stop     Stop the background refresher

            Options:
              --interval <seconds>    Refresh interval (default: 60)
              --output-dir <path>     Dashboard output directory
              --cli-path <path>       Absolute path to codexbar/CodexBarCLI
              --provider <id>         Forwarded to CodexBarCLI --provider
              --source <mode>         Forwarded to CodexBarCLI --source
              --status                Include provider status checks
              --no-open               Do not launch the browser
              -h, --help              Show this help
            """)
    }
}

private enum LinuxDashboardCommand: String {
    case launch
    case serve
    case refresh
    case open
    case stop
}

private struct LinuxDashboardOptions {
    var command: LinuxDashboardCommand = .launch
    var intervalSeconds: Int = 60
    var outputDirectory: URL = LinuxDashboardPaths.defaultOutputDirectory()
    var cliPath: String?
    var provider: String?
    var source: String?
    var includeStatus: Bool = false
    var noOpen: Bool = false
    var showHelp: Bool = false

    static func parse(arguments: [String]) throws -> LinuxDashboardOptions {
        var options = LinuxDashboardOptions()
        var index = 0

        if let first = arguments.first,
           !first.hasPrefix("-"),
           let command = LinuxDashboardCommand(rawValue: first)
        {
            options.command = command
            index += 1
        }

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "-h", "--help":
                options.showHelp = true
            case "--interval":
                index += 1
                options.intervalSeconds = try Self.parseInt(arguments, index: index, flag: arg)
            case "--output-dir":
                index += 1
                options.outputDirectory = URL(
                    fileURLWithPath: try Self.parseString(arguments, index: index, flag: arg),
                    isDirectory: true)
            case "--cli-path":
                index += 1
                options.cliPath = try Self.parseString(arguments, index: index, flag: arg)
            case "--provider":
                index += 1
                options.provider = try Self.parseString(arguments, index: index, flag: arg)
            case "--source":
                index += 1
                options.source = try Self.parseString(arguments, index: index, flag: arg)
            case "--status":
                options.includeStatus = true
            case "--no-open":
                options.noOpen = true
            default:
                throw LinuxDashboardError.usage("Unknown argument '\(arg)'")
            }
            index += 1
        }

        if options.intervalSeconds < 10 {
            throw LinuxDashboardError.usage("--interval must be at least 10 seconds")
        }

        return options
    }

    private static func parseString(_ arguments: [String], index: Int, flag: String) throws -> String {
        guard arguments.indices.contains(index) else {
            throw LinuxDashboardError.usage("Missing value for \(flag)")
        }
        return arguments[index]
    }

    private static func parseInt(_ arguments: [String], index: Int, flag: String) throws -> Int {
        let raw = try Self.parseString(arguments, index: index, flag: flag)
        guard let value = Int(raw) else {
            throw LinuxDashboardError.usage("Invalid integer for \(flag): \(raw)")
        }
        return value
    }
}

private enum LinuxDashboardError: LocalizedError {
    case usage(String)
    case cliNotFound
    case process(String)
    case decode(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message): return message
        case .cliNotFound:
            return "CodexBarCLI no encontrado. Instala el CLI o usa --cli-path."
        case let .process(message): return message
        case let .decode(message): return message
        case let .io(message): return message
        }
    }
}

private enum LinuxDashboardPaths {
    static func defaultOutputDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let stateHome = environment["XDG_STATE_HOME"], !stateHome.isEmpty {
            return URL(fileURLWithPath: stateHome, isDirectory: true)
                .appendingPathComponent("codexbar-linux", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("codexbar-linux", isDirectory: true)
    }

    static func indexHTML(in directory: URL) -> URL {
        directory.appendingPathComponent("index.html")
    }

    static func snapshotJSON(in directory: URL) -> URL {
        directory.appendingPathComponent("snapshot.json")
    }

    static func waybarJSON(in directory: URL) -> URL {
        directory.appendingPathComponent("waybar.json")
    }

    static func pidFile(in directory: URL) -> URL {
        directory.appendingPathComponent("codexbar-linux.pid")
    }

    static func logFile(in directory: URL) -> URL {
        directory.appendingPathComponent("codexbar-linux.log")
    }
}

private final class LinuxDashboardApp {
    private let options: LinuxDashboardOptions
    private let fileManager: FileManager

    init(options: LinuxDashboardOptions, fileManager: FileManager = .default) {
        self.options = options
        self.fileManager = fileManager
    }

    func run() async throws {
        try self.ensureOutputDirectory()
        switch self.options.command {
        case .launch:
            try await self.launch()
        case .serve:
            try await self.serve()
        case .refresh:
            try await self.refreshOnce()
        case .open:
            try self.openDashboard()
        case .stop:
            try self.stop()
        }
    }

    private func launch() async throws {
        try await self.refreshOnce()
        if self.currentDaemonPID() == nil {
            try self.spawnDetachedServer()
        }
        if !self.options.noOpen {
            try self.openDashboard()
        }
    }

    private func serve() async throws {
        try Self.installSignalHandlers()
        let pidURL = LinuxDashboardPaths.pidFile(in: self.options.outputDirectory)
        let pid = getpid()
        if let current = self.currentDaemonPID(), current != pid {
            throw LinuxDashboardError.process("CodexBarLinux ya se esta ejecutando con PID \(current).")
        }

        try self.writeText("\(pid)\n", to: pidURL)
        defer {
            try? self.fileManager.removeItem(at: pidURL)
        }

        repeat {
            do {
                try await self.refreshOnce()
            } catch {
                let failureHTML = LinuxDashboardRenderer.renderFailureHTML(
                    message: error.localizedDescription,
                    refreshSeconds: self.options.intervalSeconds,
                    outputDirectory: self.options.outputDirectory)
                try? self.writeText(failureHTML, to: LinuxDashboardPaths.indexHTML(in: self.options.outputDirectory))
                try? self.writeWaybarError(message: error.localizedDescription)
            }

            if linuxDashboardShouldStop != 0 { break }
            Thread.sleep(forTimeInterval: TimeInterval(self.options.intervalSeconds))
        } while linuxDashboardShouldStop == 0
    }

    private func refreshOnce() async throws {
        let fetch = try await LinuxDashboardBackend.fetch(options: self.options)
        let snapshot = LinuxDashboardSnapshot(generatedAt: Date(), providers: fetch.providers)

        let html = LinuxDashboardRenderer.renderHTML(
            snapshot: snapshot,
            refreshSeconds: self.options.intervalSeconds,
            outputDirectory: self.options.outputDirectory)
        try self.writeText(fetch.rawJSON, to: LinuxDashboardPaths.snapshotJSON(in: self.options.outputDirectory))
        try self.writeText(html, to: LinuxDashboardPaths.indexHTML(in: self.options.outputDirectory))
        try self.writeWaybarSnapshot(snapshot)
    }

    private func openDashboard() throws {
        let target = LinuxDashboardPaths.indexHTML(in: self.options.outputDirectory).path
        let launchers: [[String]] = [
            ["/usr/bin/xdg-open", target],
            ["/usr/bin/gio", "open", target],
        ]

        for launcher in launchers where self.fileManager.isExecutableFile(atPath: launcher[0]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launcher[0])
            process.arguments = Array(launcher.dropFirst())
            process.standardOutput = nil
            process.standardError = nil
            process.standardInput = nil
            do {
                try process.run()
                return
            } catch {
                continue
            }
        }

        throw LinuxDashboardError.process("No se pudo abrir el navegador. Abre manualmente \(target)")
    }

    private func stop() throws {
        let pidURL = LinuxDashboardPaths.pidFile(in: self.options.outputDirectory)
        guard let pidString = try? String(contentsOf: pidURL).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidString)
        else {
            throw LinuxDashboardError.process("No hay un proceso CodexBarLinux registrado.")
        }

        if kill(pid, SIGTERM) != 0 {
            if errno == ESRCH {
                try? self.fileManager.removeItem(at: pidURL)
                throw LinuxDashboardError.process("El PID \(pid) ya no existe.")
            }
            throw LinuxDashboardError.process("No se pudo detener el PID \(pid).")
        }
    }

    private func currentDaemonPID() -> pid_t? {
        let pidURL = LinuxDashboardPaths.pidFile(in: self.options.outputDirectory)
        guard let pidString = try? String(contentsOf: pidURL).trimmingCharacters(in: .whitespacesAndNewlines),
              let rawPID = Int32(pidString)
        else {
            return nil
        }
        let pid = pid_t(rawPID)

        if kill(pid, 0) == 0 {
            return pid
        }

        try? self.fileManager.removeItem(at: pidURL)
        return nil
    }

    private func spawnDetachedServer() throws {
        let executable = try Self.currentExecutableURL()
        let logURL = LinuxDashboardPaths.logFile(in: self.options.outputDirectory)
        if !self.fileManager.fileExists(atPath: logURL.path) {
            self.fileManager.createFile(atPath: logURL.path, contents: Data())
        }

        let logHandle = try FileHandle(forWritingTo: logURL)
        logHandle.seekToEndOfFile()

        let process = Process()
        process.executableURL = executable
        process.arguments = self.detachedServeArguments()
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = nil
        try process.run()
    }

    private func detachedServeArguments() -> [String] {
        var arguments = ["serve", "--interval", "\(self.options.intervalSeconds)", "--no-open"]
        arguments += ["--output-dir", self.options.outputDirectory.path]
        if let cliPath = self.options.cliPath {
            arguments += ["--cli-path", cliPath]
        }
        if let provider = self.options.provider {
            arguments += ["--provider", provider]
        }
        if let source = self.options.source {
            arguments += ["--source", source]
        }
        if self.options.includeStatus {
            arguments.append("--status")
        }
        return arguments
    }

    private func ensureOutputDirectory() throws {
        try self.fileManager.createDirectory(at: self.options.outputDirectory, withIntermediateDirectories: true)
    }

    private func writeText(_ value: String, to url: URL) throws {
        do {
            try value.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw LinuxDashboardError.io("No se pudo escribir \(url.path): \(error.localizedDescription)")
        }
    }

    private func writeWaybarSnapshot(_ snapshot: LinuxDashboardSnapshot) throws {
        let payload = LinuxWaybarPayload(
            text: snapshot.waybarText,
            tooltip: snapshot.waybarTooltip,
            class: snapshot.waybarClass)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LinuxDashboardError.io("No se pudo serializar waybar.json")
        }
        try self.writeText(text, to: LinuxDashboardPaths.waybarJSON(in: self.options.outputDirectory))
    }

    private func writeWaybarError(message: String) throws {
        let payload = LinuxWaybarPayload(text: "CB !", tooltip: message, class: "error")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LinuxDashboardError.io("No se pudo serializar waybar.json")
        }
        try self.writeText(text, to: LinuxDashboardPaths.waybarJSON(in: self.options.outputDirectory))
    }

    fileprivate static func currentExecutableURL() throws -> URL {
        #if os(Linux)
        let path = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        return URL(fileURLWithPath: path)
        #else
        if let url = Bundle.main.executableURL {
            return url
        }
        throw LinuxDashboardError.process("No se pudo resolver el ejecutable actual.")
        #endif
    }

    private static func installSignalHandlers() throws {
        signal(SIGINT, linuxDashboardHandleSignal)
        signal(SIGTERM, linuxDashboardHandleSignal)
    }
}

private enum LinuxDashboardBackend {
    static func fetch(options: LinuxDashboardOptions) async throws -> (rawJSON: String, providers: [LinuxProviderPayload]) {
        let binary = try self.resolveCLIBinary(explicitPath: options.cliPath)
        var arguments = ["--format", "json", "--pretty", "--json-only"]
        if let provider = options.provider {
            arguments += ["--provider", provider]
        }
        if let source = options.source {
            arguments += ["--source", source]
        }
        if options.includeStatus {
            arguments.append("--status")
        }

        let environment = ProcessInfo.processInfo.environment
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                binary: binary,
                arguments: arguments,
                environment: environment,
                timeout: 120,
                label: "codexbar-linux-refresh")
        } catch let error as SubprocessRunnerError {
            if case let .nonZeroExit(_, _) = error {
                let payload = LinuxDashboardPayloadCodec.errorPayload(from: error)
                if let payloads = try? LinuxDashboardPayloadCodec.decodePayloads(payload) {
                    return (payload, payloads)
                }
            }
            throw error
        }

        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LinuxDashboardError.process("CodexBarCLI no devolvio JSON.")
        }

        return (trimmed, try LinuxDashboardPayloadCodec.decodePayloads(trimmed))
    }

    private static func resolveCLIBinary(explicitPath: String?) throws -> String {
        let fileManager = FileManager.default
        if let explicitPath, fileManager.isExecutableFile(atPath: explicitPath) {
            return explicitPath
        }

        if let currentExecutable = try? LinuxDashboardApp.currentExecutableURL() {
            let directory = currentExecutable.deletingLastPathComponent()
            let localCandidates = [
                directory.appendingPathComponent("CodexBarCLI").path,
                directory.appendingPathComponent("codexbar").path,
            ]
            for candidate in localCandidates where fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        if let existingPATH = ProcessInfo.processInfo.environment["PATH"] {
            for directory in existingPATH.split(separator: ":").map(String.init) where !directory.isEmpty {
                for name in ["codexbar", "CodexBarCLI"] {
                    let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent(name)
                        .path
                    if fileManager.isExecutableFile(atPath: candidate) {
                        return candidate
                    }
                }
            }
        }

        let env = ProcessInfo.processInfo.environment
        let pathCandidates = [
            ShellCommandLocator.commandV("codexbar", env["SHELL"], 1.0, fileManager),
            ShellCommandLocator.commandV("CodexBarCLI", env["SHELL"], 1.0, fileManager),
        ].compactMap(\.self)
        for candidate in pathCandidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        throw LinuxDashboardError.cliNotFound
    }
}

nonisolated(unsafe) private var linuxDashboardShouldStop: sig_atomic_t = 0

private func linuxDashboardHandleSignal(_: Int32) -> Void {
    linuxDashboardShouldStop = 1
}
