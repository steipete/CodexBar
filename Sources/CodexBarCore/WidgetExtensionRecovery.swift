#if os(macOS)
import Darwin
import Foundation
import Security

@MainActor
package enum WidgetExtensionRecovery {
    struct Process: Equatable {
        let pid: Int32
        let startedAt: Date
        let executablePath: String
    }

    static let versionKey = "widgetExtensionLastLaunchedVersion"

    // swiftlint:disable:next function_parameter_count
    static func recover(
        version: String,
        defaults: UserDefaults,
        processes: () -> [Process],
        installedAt: () -> Date?,
        owns: (Process) -> Bool,
        exists: (String) -> Bool,
        terminate: (Process) -> Bool,
        reload: () -> Void) -> Int?
    {
        guard defaults.string(forKey: self.versionKey) != version else { return nil }
        defaults.set(version, forKey: self.versionKey)
        let installedAt = installedAt()
        var terminated = 0
        for process in processes() where owns(process) &&
            (!exists(process.executablePath) || installedAt.map { process.startedAt < $0 } == true)
        {
            if terminate(process) { terminated += 1 }
        }
        reload()
        return terminated
    }

    package static func launch(bundle: Bundle = .main, defaults: UserDefaults = .standard, reload: () -> Void) {
        guard !TestProcessSafety.isRunning,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              defaults.string(forKey: self.versionKey) != version,
              !version.isEmpty
        else { return }
        // Remember failed validation too: recovery is a one-shot attempt for this build.
        defer {
            defaults.set(version, forKey: self.versionKey)
            reload()
        }
        guard let identifier = bundle.bundleIdentifier,
              let team = bundle.object(forInfoDictionaryKey: "CodexBarTeamID") as? String, !team.isEmpty,
              let url = bundle.builtInPlugInsURL?.appendingPathComponent("CodexBarWidget.appex"),
              let executable = Bundle(url: url)?.executableURL
        else {
            CodexBarLog.logger("widget-recovery").info("Post-update widget recovery skipped: unavailable extension")
            return
        }
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) ==
              errSecSuccess,
              let info = info as? [String: Any],
              info[kSecCodeInfoIdentifier as String] as? String == identifier + ".widget",
              info[kSecCodeInfoTeamIdentifier as String] as? String == team,
              let expected = self.requirement(code)
        else {
            CodexBarLog.logger("widget-recovery").info("Post-update widget recovery skipped: unverified extension")
            return
        }
        let count = self.recover(
            version: version,
            defaults: defaults,
            processes: {
                DarwinProcessEnumerator.allPIDs(type: UInt32(PROC_UID_ONLY), typeInfo: getuid())
                    .compactMap { self.process(
                        $0,
                        name: executable.lastPathComponent) }
            },
            installedAt: {
                var info = stat()
                guard stat(executable.path, &info) == 0 else { return nil }
                return [info.st_mtimespec, info.st_ctimespec].map {
                    Date(timeIntervalSince1970: Double($0.tv_sec) + Double($0.tv_nsec) / 1_000_000_000)
                }.max()
            },
            owns: { self.runningRequirement($0.pid) == expected },
            exists: {
                var info = stat()
                return stat($0, &info) == 0 || (errno != ENOENT && errno != ENOTDIR)
            },
            terminate: {
                guard self.process($0.pid, name: executable.lastPathComponent) == $0,
                      self.runningRequirement($0.pid) == expected else { return false }
                return kill($0.pid, SIGTERM) == 0
            },
            reload: {})
        CodexBarLog.logger("widget-recovery").info(
            "Post-update widget recovery",
            metadata: ["version": version, "terminated": "\(count ?? 0)"])
    }

    static func process(_ pid: Int32, name: String) -> Process? {
        guard let info = DarwinProcessEnumerator.processInfo(pid: pid), info.pbi_uid == getuid(),
              withUnsafeBytes(of: info.pbi_name, { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) }) == name
        else { return nil }
        guard let path = DarwinProcessEnumerator.executablePath(pid: pid)
            ?? DarwinProcessEnumerator.arguments(pid: pid)?.first,
            path.hasPrefix("/"), URL(fileURLWithPath: path).lastPathComponent == name else { return nil }
        return Process(
            pid: pid,
            startedAt: Date(timeIntervalSince1970:
                Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000),
            executablePath: path)
    }

    static func runningRequirement(_ pid: Int32) -> Data? {
        // Ask for the running code: disk-backed signing information disappears after bundle removal.
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributePid: pid, kSecGuestAttributeDynamicCode: true] as CFDictionary,
            [],
            &code) == errSecSuccess,
            let code else { return nil }
        // Security accepts dynamic code here; Swift imports only the static CF type.
        return self.requirement(unsafeBitCast(code, to: SecStaticCode.self))
    }

    private static func requirement(_ code: SecStaticCode) -> Data? {
        var requirement: SecRequirement?
        var data: CFData?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyData(requirement, [], &data) == errSecSuccess else { return nil }
        return data as Data?
    }
}
#endif
