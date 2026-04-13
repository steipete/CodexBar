import Foundation

public enum AgentDebugLogger {
    private static let lock = NSLock()
    private static let logURL = URL(
        fileURLWithPath: "/Users/ratulsarna/Developer/staipete/CodexBar/.cursor/debug-4f7ebf.log")
    private static let sessionID = "4f7ebf"

    public static func log(
        _ message: String,
        hypothesisId: String,
        location: String,
        runId: String = "baseline",
        data: [String: String] = [:])
    {
        let payload: [String: Any] = [
            "sessionId": self.sessionID,
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let raw = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: raw, encoding: .utf8)
        else {
            return
        }
        line.append("\n")
        guard let encoded = line.data(using: .utf8) else { return }

        self.lock.lock()
        defer { self.lock.unlock() }

        if FileManager.default.fileExists(atPath: self.logURL.path),
           let handle = try? FileHandle(forWritingTo: self.logURL)
        {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: encoded)
        } else {
            try? encoded.write(to: self.logURL, options: .atomic)
        }
    }
}
