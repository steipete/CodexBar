import Foundation

enum InstallOrigin {
    static let caskroomURLs = [
        URL(fileURLWithPath: "/opt/homebrew/Caskroom"),
        URL(fileURLWithPath: "/usr/local/Caskroom"),
    ]

    static func isHomebrewCask(
        appBundleURL: URL,
        caskroomURLs: [URL] = Self.caskroomURLs) -> Bool
    {
        !self.homebrewPrefixes(appBundleURL: appBundleURL, caskroomURLs: caskroomURLs).isEmpty
    }

    static func homebrewPrefix(
        appBundleURL: URL,
        caskroomURLs: [URL] = Self.caskroomURLs) -> URL?
    {
        let prefixes = self.homebrewPrefixes(appBundleURL: appBundleURL, caskroomURLs: caskroomURLs)
        return prefixes.count == 1 ? prefixes[0] : nil
    }

    private static func homebrewPrefixes(appBundleURL: URL, caskroomURLs: [URL]) -> [URL] {
        let resolved = appBundleURL.resolvingSymlinksInPath().standardizedFileURL
        var prefixes: [URL] = []
        let legacyCask = resolved.deletingLastPathComponent().deletingLastPathComponent()
        if resolved.lastPathComponent == "CodexBar.app", legacyCask.lastPathComponent == "codexbar",
           legacyCask.deletingLastPathComponent().lastPathComponent == "Caskroom"
        {
            prefixes.append(legacyCask.deletingLastPathComponent().deletingLastPathComponent())
        }

        let fileManager = FileManager.default
        guard (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return prefixes
        }

        // Cask app artifacts are moved into the app directory. Homebrew leaves a symlink
        // in Caskroom pointing to the installed app, rather than the other way around.
        let linkedPrefixes = caskroomURLs.filter { caskroom in
            let caskURL = caskroom.appendingPathComponent("codexbar", isDirectory: true)
            guard let versions = try? fileManager.contentsOfDirectory(
                at: caskURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { return false }

            return versions.contains { version in
                let artifact = version.appendingPathComponent("CodexBar.app")
                return (try? fileManager.destinationOfSymbolicLink(atPath: artifact.path)) != nil &&
                    artifact.resolvingSymlinksInPath().standardizedFileURL == resolved
            }
        }.map { $0.deletingLastPathComponent() }
        return Array(Set((prefixes + linkedPrefixes).map { $0.resolvingSymlinksInPath().standardizedFileURL }))
    }
}
