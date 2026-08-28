#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum CodexLocalProjectRootResolver {
    public typealias ProjectIdentity = (id: String, displayName: String, path: String?)

    public static let chatsProjectId = "chats"
    public static let chatsDisplayName = "Chats"

    public static func projectIdentity(for cwd: String?) -> ProjectIdentity {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return (self.chatsProjectId, self.chatsDisplayName, nil)
        }

        let root = self.resolveProjectRoot(from: URL(fileURLWithPath: cwd, isDirectory: true))
        let canonicalRoot = self.canonicalProjectURL(root)
        let path = canonicalRoot.path
        return (
            self.projectId(for: path),
            canonicalRoot.lastPathComponent.isEmpty ? path : canonicalRoot.lastPathComponent,
            path)
    }

    public static func resolveProjectRoot(from cwd: URL) -> URL {
        let fm = FileManager.default
        let loggedCWD = cwd.standardizedFileURL
        var current = loggedCWD
        var isDirectory: ObjCBool = false
        let cwdExists = fm.fileExists(atPath: current.path, isDirectory: &isDirectory)
        // A missing CWD is historical evidence. Do not walk up to an existing
        // parent repository because that would collapse a deleted worktree or
        // folder into a different project identity.
        guard cwdExists else { return loggedCWD }
        if cwdExists, !isDirectory.boolValue {
            current = current.deletingLastPathComponent()
        }

        var candidate: URL? = current
        while let url = candidate {
            let gitURL = url.appendingPathComponent(".git")
            if fm.fileExists(atPath: gitURL.path) {
                return url.standardizedFileURL
            }
            let parent = url.deletingLastPathComponent()
            candidate = parent.path == url.path ? nil : parent
        }

        return current.standardizedFileURL
    }

    private static func canonicalProjectURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    public static func projectId(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "project-\(hex.prefix(16))"
    }
}
