import Foundation
@testable import CodexBarCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class KiroTestProcessRegistry: @unchecked Sendable {
    private struct Record {
        var processGroup: pid_t?
    }

    private let lock = NSLock()
    private let blockOnUnregister: Int?
    private let blockStartedURL: URL?
    private let unblock: DispatchSemaphore?
    private var records: [pid_t: Record] = [:]
    private var unregisteredPIDs: Set<pid_t> = []
    private var unregisterCount = 0

    init(
        blockOnUnregister: Int? = nil,
        blockStartedURL: URL? = nil,
        unblock: DispatchSemaphore? = nil)
    {
        self.blockOnUnregister = blockOnUnregister
        self.blockStartedURL = blockStartedURL
        self.unblock = unblock
    }

    var dependencies: KiroStatusProbe.PipeProcessRegistry {
        .init(
            beginLaunch: { true },
            endLaunch: {},
            register: { pid, _ in
                self.lock.withLock {
                    self.records[pid] = Record(processGroup: nil)
                }
                return true
            },
            updateProcessGroup: { pid, processGroup in
                self.lock.withLock {
                    guard self.records[pid] != nil else { return }
                    self.records[pid]?.processGroup = processGroup
                }
            },
            unregister: { pid in
                let shouldBlock = self.lock.withLock {
                    self.records.removeValue(forKey: pid)
                    self.unregisteredPIDs.insert(pid)
                    self.unregisterCount += 1
                    return self.unregisterCount == self.blockOnUnregister
                }
                if shouldBlock {
                    if let blockStartedURL = self.blockStartedURL {
                        _ = FileManager.default.createFile(atPath: blockStartedURL.path, contents: Data())
                    }
                    self.unblock?.wait()
                }
            })
    }

    func isRegistered(_ pid: pid_t) -> Bool {
        self.lock.withLock { self.records[pid] != nil }
    }

    func didUnregister(_ pid: pid_t) -> Bool {
        self.lock.withLock { self.unregisteredPIDs.contains(pid) }
    }

    func terminate(_ pid: pid_t) {
        let processGroup = self.lock.withLock { () -> pid_t? in
            self.records[pid]?.processGroup
        }
        if let processGroup, processGroup > 0, processGroup != getpgrp() {
            _ = kill(-processGroup, SIGKILL)
        }
        if pid > 0 {
            _ = kill(pid, SIGKILL)
        }
    }
}
