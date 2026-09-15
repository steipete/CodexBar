import Foundation

enum InstallOrigin {
    static func isHomebrewCask(
        appBundleURL: URL,
        caskroomURLs: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/Caskroom"),
            URL(fileURLWithPath: "/usr/local/Caskroom"),
        ]) -> Bool
    {
        let resolved = appBundleURL.resolvingSymlinksInPath().standardizedFileURL
        if resolved.path.contains("/Caskroom/") { return true }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        // Cask app artifacts are moved into the app directory. Homebrew leaves a symlink
        // in Caskroom pointing to the installed app, rather than the other way around.
        return caskroomURLs.contains { caskroom in
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
        }
    }
}
