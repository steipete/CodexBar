import Foundation

extension KeychainCacheStore {
    static func trustedApplicationPathsForCacheAccess(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String]
    {
        var paths: [String] = []
        func append(_ path: String) {
            guard !path.isEmpty, fileExists(path), !paths.contains(path) else { return }
            paths.append(path)
        }

        // No .app ancestor means an ephemeral dev binary; trusting its bare path
        // would freeze a broken ACL onto the shared item (the packaged app would
        // then prompt on every read). Refuse the ACL entirely in that case —
        // unbundled processes use the in-memory store and never reach this path
        // in practice.
        guard let appBundle = self.appBundleURL(containing: bundleURL)
            ?? executableURL.flatMap(self.appBundleURL(containing:))
        else { return [] }
        append(appBundle.path)
        append(appBundle.appendingPathComponent("Contents/Helpers/CodexBarCLI").path)
        if let executableURL {
            append(executableURL.path)
        }
        return paths
    }

    /// The caller that will perform the secret-data operation after preflight. The cache ACL may trust
    /// multiple first-party executables, but one executable cannot authorize access on another's behalf.
    static func invokingApplicationPathsForCacheAccess(
        executableURL: URL? = Bundle.main.executableURL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String]
    {
        guard let path = executableURL?.path, !path.isEmpty, fileExists(path) else { return [] }
        return [path]
    }

    static func appBundleURL(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if current.pathExtension == "app" {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }
}
