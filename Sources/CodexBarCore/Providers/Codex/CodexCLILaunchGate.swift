import Foundation

final class CodexCLILaunchGate: @unchecked Sendable {
    static let shared = CodexCLILaunchGate()
    static let cooldown: TimeInterval = 30 * 60

    private struct Entry {
        let message: String
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func backgroundSkipMessage(
        binary: String,
        now: Date = Date(),
        interaction: ProviderInteraction = ProviderInteractionContext.current) -> String?
    {
        guard interaction == .background else { return nil }

        self.lock.lock()
        defer { self.lock.unlock() }

        guard let entry = self.entries[binary] else { return nil }
        guard entry.expiresAt > now else {
            self.entries.removeValue(forKey: binary)
            return nil
        }
        return entry.message
    }

    @discardableResult
    func recordLaunchFailure(binary: String, message: String, now: Date = Date()) -> String? {
        guard Self.shouldThrottleLaunchFailure(message) else { return nil }
        let throttled = Self.throttledMessage(binary: binary, originalMessage: message)
        let entry = Entry(
            message: throttled,
            expiresAt: now.addingTimeInterval(Self.cooldown))

        self.lock.lock()
        self.entries[binary] = entry
        self.lock.unlock()

        return throttled
    }

    func resetForTesting() {
        self.lock.lock()
        self.entries.removeAll()
        self.lock.unlock()
    }

    static func shouldThrottleLaunchFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("openpty") ||
            lower.contains("write to pty") ||
            lower.contains("app shutdown")
        {
            return false
        }
        return true
    }

    private static func throttledMessage(binary: String, originalMessage: String) -> String {
        "Codex CLI launch failed; background refresh is paused for 30 minutes. " +
            "Reinstall or unblock `\(binary)` in macOS security settings, then refresh manually. " +
            "Last error: \(originalMessage)"
    }
}
