import Foundation

public enum CodexAccountLabel {
    /// This is not a manual user-labeling system. It parses the stored Codex account label
    /// into displayable identity parts so multiple accounts can be distinguished in the menu.
    public static let separator = " — "

    public struct Parts: Equatable, Sendable {
        public let email: String?
        public let workspace: String?

        public init(email: String?, workspace: String?) {
            self.email = email
            self.workspace = workspace
        }
    }

    public static func parse(_ label: String) -> Parts {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Parts(email: nil, workspace: nil) }

        if let range = trimmed.range(of: self.separator) {
            let email = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let workspace = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return Parts(
                email: email.contains("@") ? email : nil,
                workspace: workspace.isEmpty ? nil : workspace)
        }

        return Parts(
            email: trimmed.contains("@") ? trimmed : nil,
            workspace: nil)
    }

    public static func makeBaseLabel(email: String?, workspace: String?, fallbackIndex: Int) -> String {
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWorkspace = workspace?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedEmail, !trimmedEmail.isEmpty {
            if let trimmedWorkspace, !trimmedWorkspace.isEmpty {
                return "\(trimmedEmail)\(self.separator)\(trimmedWorkspace)"
            }
            return trimmedEmail
        }

        return "ChatGPT account \(fallbackIndex)"
    }

    public static func uniqueLabel(baseLabel: String, existingAccounts: [ProviderTokenAccount]) -> String {
        let existingLabels = Set(existingAccounts.map(\.label))
        guard existingLabels.contains(baseLabel) else { return baseLabel }

        var index = 2
        var candidate = "\(baseLabel) #\(index)"
        while existingLabels.contains(candidate) {
            index += 1
            candidate = "\(baseLabel) #\(index)"
        }
        return candidate
    }
}
