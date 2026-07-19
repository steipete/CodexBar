import Foundation

public enum LogMetadata {
    public static func secretSummary(_ value: String?) -> [String: String] {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = trimmed.isEmpty ? "cleared" : "set"
        let length = trimmed.count
        return ["state": state, "length": "\(length)"]
    }
}
