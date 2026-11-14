import Foundation

/// Checks transcript activity in the profile the CLI will use. Cost-scanning roots also include other profiles'
/// backups and Desktop sessions; those cannot establish activity for this CLI account.
///
/// Only file modification dates are read; transcript contents are never opened. CodexBar's own `/usage` probe
/// transcripts are ignored so that a probe cannot count as user activity.
enum ClaudeLocalSessionActivity {
    static func hasActivity(
        since date: Date,
        environment: [String: String],
        fileManager: FileManager = .default) -> Bool
    {
        let projectsRoot = ClaudeConfigPaths.configRoot(environment: environment)
            .appendingPathComponent("projects", isDirectory: true)
        let probeProjectDirectoryName = ClaudeProbeSessionArtifactCleaner.claudeProjectDirectoryName(
            for: ClaudeStatusProbe.dedicatedProbeWorkingDirectoryURL())
        return self.hasActivity(
            since: date,
            in: projectsRoot,
            excludingProjectDirectoryNamed: probeProjectDirectoryName,
            fileManager: fileManager)
    }

    /// Fails safe: a root or transcript that cannot be read counts as activity, so CodexBar probes as before rather
    /// than keep a rolled-over reading it cannot justify. A root that does not exist has no activity.
    static func hasActivity(
        since date: Date,
        in projectsRoot: URL,
        excludingProjectDirectoryNamed excludedName: String?,
        fileManager: FileManager = .default) -> Bool
    {
        // Shared-history roots may be symlinks.
        let projectsRoot = projectsRoot.resolvingSymlinksInPath()
        do {
            let attributes = try fileManager.attributesOfItem(atPath: projectsRoot.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { return true }
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
        {
            return false
        } catch {
            // `fileExists` also returns false on permission errors; only a proven missing root is idle.
            return true
        }

        let keys: [URLResourceKey] = [
            .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        ]
        let scan = ScanState()
        guard let enumerator = fileManager.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                scan.incomplete = true
                return true
            })
        else { return true }

        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else {
                return true
            }
            // DirectoryEnumerator does not follow nested links, so it cannot prove those transcripts idle.
            if values.isSymbolicLink == true { return true }
            if values.isDirectory == true {
                if enumerator.level == 1, item.lastPathComponent == excludedName {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard item.pathExtension == "jsonl", values.isRegularFile == true else { continue }
            guard let modifiedAt = values.contentModificationDate else { return true }
            if modifiedAt > date {
                return true
            }
        }
        return scan.incomplete
    }

    private final class ScanState: @unchecked Sendable {
        var incomplete = false
    }
}
