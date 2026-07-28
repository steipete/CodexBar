import Foundation

enum ClaudeProbeSessionArtifactCleaner {
    private static let log = CodexBarLog.logger(LogCategories.claudeProbe)
    private static let maxProjectDirectoryNameLength = 200

    @discardableResult
    static func cleanupProbeSessionArtifacts(
        probeDirectory: URL = ClaudeStatusProbe.probeWorkingDirectoryURL(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager fm: FileManager = .default) -> [URL]
    {
        let projectDirectoryName = self.claudeProjectDirectoryName(for: probeDirectory)
        var visitedDirectories = Set<String>()
        var removedFiles: [URL] = []

        for root in self.claudeConfigRoots(environment: environment, fileManager: fm) {
            let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
            let directories = [projectsRoot.appendingPathComponent(projectDirectoryName, isDirectory: true)]

            for directory in directories where visitedDirectories.insert(directory.path).inserted {
                guard let entries = try? fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])
                else { continue }

                for entry in entries where entry.pathExtension == "jsonl" {
                    let values = try? entry.resourceValues(forKeys: [.isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }
                    do {
                        try fm.removeItem(at: entry)
                        removedFiles.append(entry)
                    } catch {
                        Self.log.debug(
                            "Claude probe session artifact cleanup skipped file",
                            metadata: ["error": error.localizedDescription])
                    }
                }

                if (try? fm.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                    try? fm.removeItem(at: directory)
                }
            }
        }

        return removedFiles
    }

    static func claudeProjectDirectoryName(for directory: URL) -> String {
        let path = directory.path.precomposedStringWithCanonicalMapping
        let sanitized = String(path.utf16.map { codeUnit in
            switch codeUnit {
            case 48...57, 65...90, 97...122:
                Character(UnicodeScalar(codeUnit)!)
            default:
                "-"
            }
        })

        guard sanitized.count > self.maxProjectDirectoryNameLength else { return sanitized }
        return "\(sanitized.prefix(self.maxProjectDirectoryNameLength))-\(self.javaScriptHashBase36(path))"
    }

    private static func javaScriptHashBase36(_ string: String) -> String {
        var hash: Int32 = 0
        for codeUnit in string.utf16 {
            hash = hash &* 31 &+ Int32(truncatingIfNeeded: codeUnit)
        }

        let magnitude = hash < 0 ? -Int64(hash) : Int64(hash)
        return String(magnitude, radix: 36)
    }

    private static func claudeConfigRoots(
        environment: [String: String],
        fileManager _: FileManager) -> [URL]
    {
        [ClaudeConfigPaths.configRoot(environment: environment)]
    }
}
