import Foundation

public enum CodeRabbitUsageParser {
    public static func parse(usageText: String, now: Date = Date()) throws -> CodeRabbitUsageSnapshot {
        let text = TextParsing.stripANSICodes(usageText)
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, fields[label] == nil { fields[label] = value }
        }
        let reviews = fields["your reviews"].flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
        guard reviews != nil || fields["usage billing"] != nil || fields["period resets"] != nil else {
            if self.looksSignedOut(text) { throw CodeRabbitUsageError.notLoggedIn }
            throw CodeRabbitUsageError.parseFailed
        }
        return CodeRabbitUsageSnapshot(
            organization: fields["organization"],
            user: fields["user"],
            plan: fields["plan"],
            reviewsCount: reviews,
            usageBilling: fields["usage billing"],
            periodResets: fields["period resets"],
            updatedAt: now)
    }

    static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return [
            "not authenticated",
            "please log in",
            "auth login",
            "authentication required",
            "unauthorized",
            "no session found",
        ].contains { lower.contains($0) }
    }
}
