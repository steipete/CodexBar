import CodexBarCore
import Foundation

@MainActor
final class ClaudeWarmingService {
    private static let log = CodexBarLog.logger(LogCategories.claudeWarming)
    private static let pingInterval: TimeInterval = 3600
    private static let windowDuration: TimeInterval = 5 * 3600
    private static let windowStartTimeKey = "claudeWarmingWindowStartTime"
    private static let authFailurePatterns = ["not logged in", "login", "unauthorized", "auth error"]

    private var timer: Timer?
    private(set) var lastPingTime: Date?
    private(set) var lastPingSuccess: Bool = true
    private(set) var lastPingMessage: String = ""
    private(set) var windowStartTime: Date? {
        didSet {
            if let t = windowStartTime {
                UserDefaults.standard.set(t, forKey: Self.windowStartTimeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.windowStartTimeKey)
            }
        }
    }

    var onStatusChanged: (() -> Void)?

    var windowResetsAt: Date? {
        guard let start = windowStartTime else { return nil }
        return start.addingTimeInterval(Self.windowDuration)
    }

    var nextPingTime: Date? {
        guard let last = lastPingTime else { return nil }
        return last.addingTimeInterval(Self.pingInterval)
    }

    init() {
        if let saved = UserDefaults.standard.object(forKey: Self.windowStartTimeKey) as? Date {
            if Date().timeIntervalSince(saved) < Self.windowDuration {
                windowStartTime = saved
            }
        }
    }

    func start() {
        guard timer == nil else { return }
        Self.log.info("Warming service started")

        Task { await self.ping() }

        timer = Timer.scheduledTimer(withTimeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.ping()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        Self.log.info("Warming service stopped")
    }

    func pingNow() {
        Task { await self.ping() }
    }

    var isRunning: Bool {
        timer != nil
    }

    private func ping() async {
        guard let claudePath = ClaudeCLIResolver.resolvedBinaryPath() else {
            lastPingTime = Date()
            lastPingSuccess = false
            lastPingMessage = "CLI not found"
            Self.log.warning("Claude CLI not found, skipping ping")
            onStatusChanged?()
            return
        }

        let (output, exitCode) = await runClaude(at: claudePath)
        lastPingTime = Date()

        let isAuthFailure = exitCode != 0 || Self.authFailurePatterns.contains { pattern in
            output.localizedCaseInsensitiveContains(pattern)
        }

        if isAuthFailure {
            lastPingSuccess = false
            lastPingMessage = "Auth failure"
            Self.log.warning(
                "Ping auth failure",
                metadata: ["exitCode": "\(exitCode)", "response": "\(output.prefix(200))"])
        } else {
            lastPingSuccess = true
            lastPingMessage = "OK"
            Self.log.info(
                "Ping succeeded",
                metadata: ["exitCode": "\(exitCode)", "responseLength": "\(output.count)"])

            if let resetAt = windowResetsAt, Date() > resetAt {
                windowStartTime = Date()
            } else if windowStartTime == nil {
                windowStartTime = Date()
            }
        }

        onStatusChanged?()
    }

    private static let processTimeout: TimeInterval = 60

    private func runClaude(at path: String) async -> (String, Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["-p", ".", "--model", "haiku"]
                process.standardOutput = pipe
                process.standardError = pipe
                process.environment = ProcessInfo.processInfo.environment

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ("Process launch failed: \(error)", 1))
                    return
                }

                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + Self.processTimeout)
                timer.setEventHandler {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                timer.resume()

                process.waitUntilExit()
                timer.cancel()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(returning: ("Process timed out after \(Int(Self.processTimeout))s", 1))
                } else {
                    continuation.resume(returning: (output, process.terminationStatus))
                }
            }
        }
    }

    static func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
