#if os(macOS)
import Foundation
import SweetCookieKit

/// Locates raw LevelDB sources; each caller supplies its own browser allowlist and origin decoder.
enum ChromiumLocalStorageDiscovery {
    struct Candidate {
        let label: String
        let url: URL
    }

    static func candidates(
        browserDetection: BrowserDetection,
        browsers: [Browser]) -> [Candidate]
    {
        let installedBrowsers = browsers.browsersWithProfileData(using: browserDetection)
        return self.candidates(browsers: installedBrowsers)
    }

    static func candidates(browsers: [Browser]) -> [Candidate] {
        let roots = ChromiumProfileLocator
            .roots(for: browsers, homeDirectories: BrowserCookieClient.defaultHomeDirectories())
            .map { (url: $0.url, labelPrefix: $0.labelPrefix) }

        var candidates: [Candidate] = []
        for root in roots {
            candidates.append(contentsOf: self.profileCandidates(
                root: root.url,
                labelPrefix: root.labelPrefix))
        }
        return candidates
    }

    static func profileCandidates(root: URL, labelPrefix: String) -> [Candidate] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let profileDirs = entries.filter { url in
            guard let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory), isDir else {
                return false
            }
            let name = url.lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return profileDirs.compactMap { dir in
            let levelDBURL = dir.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
            guard FileManager.default.fileExists(atPath: levelDBURL.path) else { return nil }
            let label = "\(labelPrefix) \(dir.lastPathComponent)"
            return Candidate(label: label, url: levelDBURL)
        }
    }
}
#endif
