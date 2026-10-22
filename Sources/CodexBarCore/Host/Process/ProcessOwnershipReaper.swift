#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// A per-launch capability inherited across exec, setsid, and reparenting. Never infer ownership from cwd or argv.
struct ProcessOwnershipReaper: Sendable {
    static let environmentKey = "CODEXBAR_PROBE_OWNER"
    let marker = UUID().uuidString

    func reap(processGroup: pid_t? = nil) {
        // A live marked member must still witness group ownership after the leader exits.
        if let processGroup {
            self.signalGroup(processGroup, signal: SIGTERM)
        }
        let deadline = Date().addingTimeInterval(0.4)
        repeat {
            let identities = self.ownedProcesses()
            if identities.isEmpty { return }
            for identity in identities {
                Self.signal(identity, SIGTERM, owns: self.owns)
            }
            usleep(50000)
        } while Date() < deadline
        if let processGroup {
            self.signalGroup(processGroup, signal: SIGKILL)
        }
        for identity in self.ownedProcesses() {
            Self.signal(identity, SIGKILL, owns: self.owns)
        }
    }

    private func signalGroup(_ group: pid_t, signal: Int32) {
        guard group > 0, group != getpgrp() else { return }
        for identity in self.ownedProcesses() where getpgid(identity.pid) == group {
            guard self.owns(identity.pid), TTYProcessTreeTerminator.isCurrent(identity),
                  getpgid(identity.pid) == group else { continue }
            kill(-group, signal)
            return
        }
    }

    private func ownedProcesses() -> [TTYProcessTreeTerminator.ProcessIdentity] {
        #if canImport(Darwin)
        let pids = DarwinProcessEnumerator.allPIDs()
        #else
        let pids = ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []).compactMap { pid_t($0) }
        #endif
        return pids.compactMap { pid in
            guard let identity = TTYProcessTreeTerminator.processIdentity(for: pid), self.owns(pid),
                  TTYProcessTreeTerminator.isCurrent(identity) else { return nil }
            return identity
        }
    }

    private func owns(_ pid: pid_t) -> Bool {
        guard pid > 0, pid != getpid() else { return false }
        #if canImport(Darwin)
        guard DarwinProcessEnumerator.processInfo(pid: pid)?.pbi_uid == getuid() else { return false }
        let environment = DarwinProcessEnumerator.environment(pid: pid, names: [Self.environmentKey])
        #else
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: "/proc/\(pid)"),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return false }
        let environment = PiProcessEnvironment.readLinuxEnvironment(pid: pid, names: [Self.environmentKey])
        #endif
        return environment?[Self.environmentKey] == self.marker
    }

    /// Revalidate at each signal, including escalation: a cached PID is never authority to kill.
    static func signal(
        _ identity: TTYProcessTreeTerminator.ProcessIdentity,
        _ signal: Int32,
        owns: (pid_t) -> Bool,
        isCurrent: (TTYProcessTreeTerminator.ProcessIdentity) -> Bool = TTYProcessTreeTerminator.isCurrent,
        send: (pid_t, Int32) -> Void = { kill($0, $1) })
    {
        guard owns(identity.pid), isCurrent(identity) else { return }
        send(identity.pid, signal)
    }
}
