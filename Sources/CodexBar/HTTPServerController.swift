import Foundation
import Observation

@MainActor
@Observable
final class HTTPServerController {
    private(set) var configuration = HTTPServerConfiguration()
    private(set) var status = "Stopped"
    private(set) var isTransitioning = false
    private(set) var runningURL: String?
    private let configURL: URL
    private let helperURL: URL
    private var child: Process?
    private var reader: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var isShuttingDown = false

    init(
        configURL: URL,
        helperURL: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/CodexBarCLI"))
    {
        self.configURL = configURL
        self.helperURL = helperURL
    }

    func startSaved() async {
        guard !self.isShuttingDown else { return }
        do {
            self.configuration = try HTTPServerConfiguration.load(from: self.configURL)
            if self.configuration.enabled { await self.restart() }
        } catch {
            self.status = "Could not read HTTP server settings. The server is stopped."
        }
    }

    func apply(_ configuration: HTTPServerConfiguration) async {
        guard !self.isTransitioning, !self.isShuttingDown else { return }
        if configuration.enabled, let error = configuration.validationError {
            self.status = error
            return
        }
        do {
            try configuration.save(to: self.configURL)
            self.configuration = configuration
            await self.restart()
        } catch {
            self.status = "Could not save HTTP server settings."
        }
    }

    func stopForTermination() -> Task<Void, Never>? {
        self.isShuttingDown = true
        return self.detachChild()
    }

    func stop() async {
        self.isTransitioning = true
        await self.detachChild()?.value
        self.shutdownTask = nil
        self.status = "Stopped"
        self.isTransitioning = false
    }

    private func detachChild() -> Task<Void, Never>? {
        self.runningURL = nil
        guard let child = self.child else { return self.shutdownTask }
        self.status = "Stopping…"
        self.child = nil
        self.reader?.cancel()
        self.reader = nil
        if child.isRunning { child.terminate() }
        let shutdown = Task.detached {
            // Let serve drain its own requests and subprocesses before enforcing shutdown.
            for _ in 0..<100 where child.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        self.shutdownTask = shutdown
        return shutdown
    }

    private func restart() async {
        await self.stop()
        guard !self.isShuttingDown, self.configuration.enabled else { self.status = "Stopped"; return }
        if let error = self.configuration.validationError { self.status = error; return }
        self.isTransitioning = true
        defer { self.isTransitioning = false }
        let process = Process()
        process.executableURL = self.helperURL
        process.arguments = self.configuration.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CODEXBAR_DASHBOARD_TOKEN"] = self.configuration.token
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe
        let url = self.configuration.url
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.child === process else { return }
                self.child = nil
                self.runningURL = nil
                self.status = "Server exited (status \(process.terminationStatus)). Check the bind address and port."
            }
        }
        do {
            try process.run()
            self.child = process
            self.status = "Starting…"
            self.reader = Task.detached { [weak self] in
                var pending = Data()
                while !Task.isCancelled {
                    let data = pipe.fileHandleForReading.availableData
                    guard !data.isEmpty else { break }
                    pending.append(data)
                    if String(bytes: pending, encoding: .utf8)?.contains("CodexBar server listening on ") == true {
                        await self?.didStart(process, url: url)
                        pending.removeAll()
                    }
                    if pending.count > 4096 { pending.removeFirst(pending.count - 4096) }
                }
            }
        } catch {
            self.status = "Could not launch the bundled HTTP server helper."
        }
    }

    private func didStart(_ process: Process, url: String) {
        guard self.child === process, process.isRunning else { return }
        self.runningURL = url
        self.status = "Running"
    }
}
