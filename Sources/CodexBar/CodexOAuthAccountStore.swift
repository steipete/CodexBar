import CodexBarCore
import Foundation

enum CodexOAuthAccountStore {
    static func createProfileDirectory(
        label: String,
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default) throws -> URL
    {
        let root = rootDirectory ?? CodexBarConfigStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("codex-oauth-accounts", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let slug = self.slug(for: label)
        let directory = root.appendingPathComponent("\(slug)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func removeProfileDirectoryIfPresent(_ directory: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory)
    }

    private static func slug(for label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slug = trimmed.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(slug)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "codex-account" : collapsed
    }
}
