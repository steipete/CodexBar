#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

package final class SpawnedProcessGroup: @unchecked Sendable {
    package enum LaunchError: LocalizedError {
        case setupFailed(String)
        case spawnFailed(String)

        package var errorDescription: String? {
            switch self {
            case let .setupFailed(details):
                "Failed to prepare process: \(details)"
            case let .spawnFailed(details):
                "Failed to launch process: \(details)"
            }
        }
    }

    private final class TerminationState: @unchecked Sendable {
        private let condition = NSCondition()
        private var exitObserved = false
        private var reapRequested = false
        private var status: Int32?

        var hasObservedExit: Bool {
            self.condition.withLock { self.exitObserved }
        }

        var value: Int32? {
            self.condition.withLock { self.status }
        }

        func observeExit() {
            self.condition.withLock {
                self.exitObserved = true
                self.condition.broadcast()
            }
        }

        func requestReap() {
            self.condition.withLock {
                self.reapRequested = true
                self.condition.broadcast()
            }
        }

        func waitForReapRequest(timeout: TimeInterval) {
            let deadline = Date().addingTimeInterval(timeout)
            self.condition.lock()
            while !self.reapRequested, self.condition.wait(until: deadline) {}
            self.condition.unlock()
        }

        func resolve(_ status: Int32) {
            self.condition.withLock {
                guard self.status == nil else { return }
                self.status = status
                self.condition.broadcast()
            }
        }
    }

    private final class ProcessIdentityState: @unchecked Sendable {
        private let lock = NSLock()
        private var identities: Set<TTYProcessTreeTerminator.ProcessIdentity> = []

        var snapshot: Set<TTYProcessTreeTerminator.ProcessIdentity> {
            self.lock.withLock { self.identities }
        }

        func formUnion(_ identities: Set<TTYProcessTreeTerminator.ProcessIdentity>) {
            self.lock.withLock {
                self.identities.formUnion(identities)
            }
        }
    }

    private struct OutputPipeIdentity: Hashable {
        #if canImport(Darwin)
        let firstHandle: UInt64
        let secondHandle: UInt64
        #else
        let inode: UInt64
        #endif

        static func resolve(fileDescriptor: Int32) -> OutputPipeIdentity? {
            #if canImport(Darwin)
            var info = pipe_fdinfo()
            let byteCount = proc_pidfdinfo(
                getpid(),
                fileDescriptor,
                PROC_PIDFDPIPEINFO,
                &info,
                Int32(MemoryLayout<pipe_fdinfo>.size))
            guard byteCount == MemoryLayout<pipe_fdinfo>.size else { return nil }
            let handles = [info.pipeinfo.pipe_handle, info.pipeinfo.pipe_peerhandle].sorted()
            guard handles[0] != 0, handles[1] != 0 else { return nil }
            return OutputPipeIdentity(firstHandle: handles[0], secondHandle: handles[1])
            #else
            var info = stat()
            guard fstat(fileDescriptor, &info) == 0 else { return nil }
            return OutputPipeIdentity(inode: UInt64(info.st_ino))
            #endif
        }

        static func holderPIDs(for pipes: Set<OutputPipeIdentity>) -> Set<pid_t> {
            guard !pipes.isEmpty else { return [] }
            #if canImport(Darwin)
            return Set(SpawnedProcessGroup.allProcessIDs().filter { self.process(pid: $0, holdsAny: pipes) })
            #else
            let targets = Set(pipes.map { "pipe:[\($0.inode)]" })
            return Set(SpawnedProcessGroup.allProcessIDs().filter { pid in
                let directory = "/proc/\(pid)/fd"
                guard let descriptors = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                    return false
                }
                return descriptors.contains { descriptor in
                    let path = "\(directory)/\(descriptor)"
                    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
                        return false
                    }
                    return targets.contains(target)
                }
            })
            #endif
        }

        #if canImport(Darwin)
        private static func process(pid: pid_t, holdsAny pipes: Set<OutputPipeIdentity>) -> Bool {
            let requiredBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard requiredBytes > 0 else { return false }
            let stride = MemoryLayout<proc_fdinfo>.stride
            var descriptors = [proc_fdinfo](
                repeating: proc_fdinfo(),
                count: Int(requiredBytes) / stride + 8)
            let actualBytes = descriptors.withUnsafeMutableBytes { buffer in
                proc_pidinfo(
                    pid,
                    PROC_PIDLISTFDS,
                    0,
                    buffer.baseAddress,
                    Int32(buffer.count))
            }
            guard actualBytes > 0 else { return false }

            for descriptor in descriptors.prefix(Int(actualBytes) / stride)
                where descriptor.proc_fdtype == PROX_FDTYPE_PIPE
            {
                var info = pipe_fdinfo()
                let byteCount = proc_pidfdinfo(
                    pid,
                    descriptor.proc_fd,
                    PROC_PIDFDPIPEINFO,
                    &info,
                    Int32(MemoryLayout<pipe_fdinfo>.size))
                guard byteCount == MemoryLayout<pipe_fdinfo>.size else { continue }
                let handles = [info.pipeinfo.pipe_handle, info.pipeinfo.pipe_peerhandle].sorted()
                let identity = OutputPipeIdentity(firstHandle: handles[0], secondHandle: handles[1])
                if pipes.contains(identity) {
                    return true
                }
            }
            return false
        }
        #endif
    }

    private struct OutputTTYIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
        let rawDevice: UInt64

        static func resolve(fileDescriptor: Int32) -> OutputTTYIdentity? {
            var info = stat()
            guard fstat(fileDescriptor, &info) == 0 else { return nil }
            #if canImport(Darwin)
            let device = SpawnedProcessGroup.darwinDeviceIdentifier(info.st_dev)
            let rawDevice = SpawnedProcessGroup.darwinDeviceIdentifier(info.st_rdev)
            #else
            let device = UInt64(info.st_dev)
            let rawDevice = UInt64(info.st_rdev)
            #endif
            return OutputTTYIdentity(
                device: device,
                inode: UInt64(info.st_ino),
                rawDevice: rawDevice)
        }

        static func holderPIDs(for terminals: Set<OutputTTYIdentity>) -> Set<pid_t> {
            guard !terminals.isEmpty else { return [] }
            #if canImport(Darwin)
            return Set(SpawnedProcessGroup.allProcessIDs().filter { self.process(pid: $0, holdsAny: terminals) })
            #else
            return Set(SpawnedProcessGroup.allProcessIDs().filter { pid in
                let directory = "/proc/\(pid)/fd"
                guard let descriptors = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                    return false
                }
                return descriptors.contains { descriptor in
                    var info = stat()
                    let path = "\(directory)/\(descriptor)"
                    guard path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else { return false }
                    let identity = OutputTTYIdentity(
                        device: UInt64(info.st_dev),
                        inode: UInt64(info.st_ino),
                        rawDevice: UInt64(info.st_rdev))
                    return terminals.contains(identity)
                }
            })
            #endif
        }

        #if canImport(Darwin)
        private static func process(pid: pid_t, holdsAny terminals: Set<OutputTTYIdentity>) -> Bool {
            let requiredBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard requiredBytes > 0 else { return false }
            let stride = MemoryLayout<proc_fdinfo>.stride
            var descriptors = [proc_fdinfo](
                repeating: proc_fdinfo(),
                count: Int(requiredBytes) / stride + 8)
            let actualBytes = descriptors.withUnsafeMutableBytes { buffer in
                proc_pidinfo(
                    pid,
                    PROC_PIDLISTFDS,
                    0,
                    buffer.baseAddress,
                    Int32(buffer.count))
            }
            guard actualBytes > 0 else { return false }

            for descriptor in descriptors.prefix(Int(actualBytes) / stride)
                where descriptor.proc_fdtype == PROX_FDTYPE_VNODE
            {
                var info = vnode_fdinfo()
                let byteCount = proc_pidfdinfo(
                    pid,
                    descriptor.proc_fd,
                    PROC_PIDFDVNODEINFO,
                    &info,
                    Int32(MemoryLayout<vnode_fdinfo>.size))
                guard byteCount == MemoryLayout<vnode_fdinfo>.size else { continue }
                let stats = info.pvi.vi_stat
                let identity = OutputTTYIdentity(
                    device: UInt64(stats.vst_dev),
                    inode: stats.vst_ino,
                    rawDevice: UInt64(stats.vst_rdev))
                if terminals.contains(identity) {
                    return true
                }
            }
            return false
        }
        #endif
    }

    private static func allProcessIDs() -> [pid_t] {
        #if canImport(Darwin)
        return self.processIDs(type: UInt32(PROC_ALL_PIDS), typeInfo: 0)
        #else
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
        return entries.compactMap(pid_t.init)
        #endif
    }

    #if canImport(Darwin)
    /// Darwin exposes `stat` device IDs as signed values while vnode inspection uses the same bits unsigned.
    package static func darwinDeviceIdentifier(_ value: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: value))
    }
    #endif

    private static func processIDs(inProcessGroup processGroup: pid_t) -> [pid_t] {
        #if canImport(Darwin)
        return self.processIDs(type: UInt32(PROC_PGRP_ONLY), typeInfo: UInt32(bitPattern: processGroup))
        #else
        return self.allProcessIDs().filter { getpgid($0) == processGroup }
        #endif
    }

    #if canImport(Darwin)
    private static func processIDs(type: UInt32, typeInfo: UInt32) -> [pid_t] {
        let requiredBytes = proc_listpids(type, typeInfo, nil, 0)
        guard requiredBytes > 0 else { return [] }
        let stride = MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: Int(requiredBytes) / stride + 32)
        let actualBytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(
                type,
                typeInfo,
                buffer.baseAddress,
                Int32(buffer.count))
        }
        guard actualBytes > 0 else { return [] }
        return Array(pids.prefix(Int(actualBytes) / stride)).filter { $0 > 0 }
    }
    #endif

    package let pid: pid_t
    package let processGroup: pid_t
    private let termination = TerminationState()
    private let observedProcessGroupMembers = ProcessIdentityState()
    private let outputPipes: Set<OutputPipeIdentity>
    private let outputTTYs: Set<OutputTTYIdentity>
    private let rootIdentity: TTYProcessTreeTerminator.ProcessIdentity?

    private init(
        pid: pid_t,
        outputPipes: Set<OutputPipeIdentity>,
        outputTTYs: Set<OutputTTYIdentity> = [])
    {
        self.pid = pid
        self.processGroup = pid
        self.outputPipes = outputPipes
        self.outputTTYs = outputTTYs
        self.rootIdentity = TTYProcessTreeTerminator.processIdentity(for: pid)
        self.startWaiter()
    }

    package static func launch(
        binary: String,
        arguments: [String],
        environment: [String: String],
        stdoutPipe: Pipe,
        stderrPipe: Pipe) throws -> SpawnedProcessGroup
    {
        #if canImport(Darwin)
        var fileActions: posix_spawn_file_actions_t?
        #else
        var fileActions = posix_spawn_file_actions_t()
        #endif
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw LaunchError.setupFailed("posix_spawn_file_actions_init")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let stdoutRead = stdoutPipe.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrRead = stderrPipe.fileHandleForReading.fileDescriptor
        let stderrWrite = stderrPipe.fileHandleForWriting.fileDescriptor
        let outputPipes = Set(
            [stdoutRead, stderrRead].compactMap(OutputPipeIdentity.resolve(fileDescriptor:)))
        var fileActionResults = [
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO),
        ]
        for descriptor in Self.pipeDescriptorsToClose([stdoutRead, stdoutWrite, stderrRead, stderrWrite]) {
            fileActionResults.append(posix_spawn_file_actions_addclose(&fileActions, descriptor))
        }
        #if canImport(Glibc) || canImport(Musl)
        do {
            try PosixSpawnFileActionsCloseFrom.addCloseFrom(
                &fileActions,
                startingAt: STDERR_FILENO + 1)
        } catch {
            throw LaunchError.setupFailed(error.localizedDescription)
        }
        #endif
        guard fileActionResults.allSatisfy({ $0 == 0 }) else {
            throw LaunchError.setupFailed("posix_spawn file actions")
        }

        #if canImport(Darwin)
        var attributes: posix_spawnattr_t?
        #else
        var attributes = posix_spawnattr_t()
        #endif
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw LaunchError.setupFailed("posix_spawnattr_init")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        #if canImport(Darwin)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
        #else
        let flags = POSIX_SPAWN_SETPGROUP
        #endif
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw LaunchError.setupFailed("posix_spawn process group")
        }

        var cArguments: [UnsafeMutablePointer<CChar>?] = ([binary] + arguments).map { strdup($0) }
        cArguments.append(nil)
        defer {
            for argument in cArguments {
                free(argument)
            }
        }

        var cEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { key, value in
            strdup("\(key)=\(value)")
        }
        cEnvironment.append(nil)
        defer {
            for entry in cEnvironment {
                free(entry)
            }
        }

        var pid: pid_t = 0
        let spawnResult = binary.withCString { path in
            posix_spawn(&pid, path, &fileActions, &attributes, cArguments, cEnvironment)
        }
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        guard spawnResult == 0 else {
            throw LaunchError.spawnFailed(String(cString: strerror(spawnResult)))
        }
        return SpawnedProcessGroup(pid: pid, outputPipes: outputPipes)
    }

    package static func launchPTY(
        binary: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        fileDescriptors: (primary: Int32, secondary: Int32)) throws -> SpawnedProcessGroup
    {
        let primaryFD = fileDescriptors.primary
        let secondaryFD = fileDescriptors.secondary
        guard let outputTTY = OutputTTYIdentity.resolve(fileDescriptor: secondaryFD) else {
            throw LaunchError.setupFailed("resolve PTY identity")
        }
        #if canImport(Darwin)
        var fileActions: posix_spawn_file_actions_t?
        #else
        var fileActions = posix_spawn_file_actions_t()
        #endif
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw LaunchError.setupFailed("posix_spawn_file_actions_init")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var fileActionResults = [
            posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, STDERR_FILENO),
        ]
        for descriptor in Self.pipeDescriptorsToClose([primaryFD, secondaryFD]) {
            fileActionResults.append(posix_spawn_file_actions_addclose(&fileActions, descriptor))
        }
        if let workingDirectory {
            fileActionResults.append(workingDirectory.path.withCString { path in
                posix_spawn_file_actions_addchdir_np(&fileActions, path)
            })
        }
        #if canImport(Glibc) || canImport(Musl)
        do {
            try PosixSpawnFileActionsCloseFrom.addCloseFrom(
                &fileActions,
                startingAt: STDERR_FILENO + 1)
        } catch {
            throw LaunchError.setupFailed(error.localizedDescription)
        }
        #endif
        guard fileActionResults.allSatisfy({ $0 == 0 }) else {
            throw LaunchError.setupFailed("posix_spawn PTY file actions")
        }

        #if canImport(Darwin)
        var attributes: posix_spawnattr_t?
        #else
        var attributes = posix_spawnattr_t()
        #endif
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw LaunchError.setupFailed("posix_spawnattr_init")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        #if canImport(Darwin)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
        #else
        let flags = POSIX_SPAWN_SETPGROUP
        #endif
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw LaunchError.setupFailed("posix_spawn PTY process group")
        }

        var cArguments: [UnsafeMutablePointer<CChar>?] = ([binary] + arguments).map { strdup($0) }
        cArguments.append(nil)
        defer {
            for argument in cArguments {
                free(argument)
            }
        }

        var cEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { key, value in
            strdup("\(key)=\(value)")
        }
        cEnvironment.append(nil)
        defer {
            for entry in cEnvironment {
                free(entry)
            }
        }

        var pid: pid_t = 0
        let spawnResult = binary.withCString { path in
            posix_spawn(&pid, path, &fileActions, &attributes, cArguments, cEnvironment)
        }
        guard spawnResult == 0 else {
            throw LaunchError.spawnFailed(String(cString: strerror(spawnResult)))
        }
        return SpawnedProcessGroup(pid: pid, outputPipes: [], outputTTYs: [outputTTY])
    }

    package var isRunning: Bool {
        !self.termination.hasObservedExit
    }

    package var terminationStatus: Int32? {
        self.termination.value
    }

    package var hasResidualProcessGroup: Bool {
        Self.processGroupExists(self.processGroup)
    }

    @discardableResult
    package func terminateSynchronously(grace: TimeInterval = 0.4) -> Int32? {
        let deadline = Date().addingTimeInterval(max(0, grace))
        var processIdentities = self.currentResidualProcessIdentities(includeDescendants: true)
        processIdentities.formUnion(self.currentProcessGroupMemberIdentities())
        if let rootIdentity = self.rootIdentity {
            processIdentities.insert(rootIdentity)
        }
        Self.signal(processIdentities: processIdentities, signal: SIGTERM)

        while processIdentities.contains(where: TTYProcessTreeTerminator.isCurrent(_:)),
              Date() < deadline
        {
            usleep(20000)
        }

        processIdentities.formUnion(self.currentResidualProcessIdentities(includeDescendants: self.isRunning))
        processIdentities.formUnion(self.currentProcessGroupMemberIdentities())
        if self.isRunning, let rootIdentity = self.rootIdentity {
            processIdentities.insert(rootIdentity)
        }
        Self.signal(processIdentities: processIdentities, signal: SIGKILL)

        let killDeadline = Date().addingTimeInterval(max(0, grace))
        while processIdentities.contains(where: TTYProcessTreeTerminator.isCurrent(_:)),
              Date() < killDeadline
        {
            usleep(20000)
        }
        return self.finishSynchronously()
    }

    @discardableResult
    package func finishSynchronously(timeout: TimeInterval = 1) -> Int32? {
        self.termination.requestReap()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while self.terminationStatus == nil, Date() < deadline {
            usleep(10000)
        }
        return self.terminationStatus
    }

    @discardableResult
    package func terminate(grace: TimeInterval = 0.4) async -> Int32? {
        if self.isRunning {
            let killDeadline = Date().addingTimeInterval(max(0, grace))
            var processIdentities = self.currentResidualProcessIdentities(includeDescendants: true)
            processIdentities.formUnion(self.currentProcessGroupMemberIdentities())
            if let rootIdentity = TTYProcessTreeTerminator.processIdentity(for: self.pid) {
                processIdentities.insert(rootIdentity)
            }
            Self.signal(processIdentities: processIdentities, signal: SIGTERM)
            _ = await self.waitForExit(timeout: max(0, killDeadline.timeIntervalSinceNow))
            while processIdentities.contains(where: TTYProcessTreeTerminator.isCurrent(_:)),
                  Date() < killDeadline
            {
                try? await Task.sleep(for: .milliseconds(20))
            }

            processIdentities.formUnion(self.currentResidualProcessIdentities(includeDescendants: false))
            processIdentities.formUnion(self.currentProcessGroupMemberIdentities())
            if self.isRunning {
                processIdentities.formUnion(self.currentResidualProcessIdentities(includeDescendants: true))
                if let rootIdentity = TTYProcessTreeTerminator.processIdentity(for: self.pid) {
                    processIdentities.insert(rootIdentity)
                }
                Self.signal(processIdentities: processIdentities, signal: SIGKILL)
                _ = await self.waitForExit(timeout: grace)
            } else {
                Self.signal(processIdentities: processIdentities, signal: SIGKILL)
            }
            _ = await self.waitForResidualProcessesExit(processIdentities, timeout: grace)
            await self.finish()
            return self.terminationStatus
        }
        await self.terminateResidualProcesses(grace: grace)
        await self.finish()
        return self.terminationStatus
    }

    package func terminateResidualProcesses(grace: TimeInterval = 0.4) async {
        let deadline = Date().addingTimeInterval(max(0, grace))
        var processIdentities = self.currentResidualProcessIdentities(includeDescendants: false)
        processIdentities.formUnion(self.currentProcessGroupMemberIdentities())
        if self.isRunning {
            processIdentities.formUnion(self.currentResidualProcessIdentities(includeDescendants: true))
            if let rootIdentity = TTYProcessTreeTerminator.processIdentity(for: self.pid) {
                processIdentities.insert(rootIdentity)
            }
        }
        Self.signal(processIdentities: processIdentities, signal: SIGTERM)

        while processIdentities.contains(where: TTYProcessTreeTerminator.isCurrent(_:)) {
            guard Date() < deadline else { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        processIdentities.formUnion(self.currentResidualProcessIdentities(includeDescendants: false))
        processIdentities.formUnion(self.currentProcessGroupMemberIdentities())
        if self.isRunning {
            processIdentities.formUnion(self.currentResidualProcessIdentities(includeDescendants: true))
            if let rootIdentity = TTYProcessTreeTerminator.processIdentity(for: self.pid) {
                processIdentities.insert(rootIdentity)
            }
        }
        guard processIdentities.contains(where: TTYProcessTreeTerminator.isCurrent(_:)) else {
            return
        }
        Self.signal(processIdentities: processIdentities, signal: SIGKILL)
        _ = await self.waitForResidualProcessesExit(processIdentities, timeout: grace)
    }

    package func finish() async {
        self.termination.requestReap()
        _ = await self.waitForTerminationStatus(timeout: 1)
    }

    private func startWaiter() {
        let pid = self.pid
        let processGroup = self.processGroup
        let observedProcessGroupMembers = self.observedProcessGroupMembers
        let termination = self.termination
        DispatchQueue.global(qos: .userInitiated).async {
            var info = siginfo_t()
            var waitResult: Int32
            repeat {
                waitResult = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
            } while waitResult == -1 && errno == EINTR
            guard waitResult == 0 else {
                termination.observeExit()
                termination.resolve(1)
                return
            }

            // The exited root remains unreaped here, so its PID cannot yet be reused as
            // an unrelated process-group ID.
            observedProcessGroupMembers.formUnion(
                Self.processGroupMemberIdentities(processGroup: processGroup, excluding: pid))
            termination.observeExit()
            termination.waitForReapRequest(timeout: 30)

            var rawStatus: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(pid, &rawStatus, 0)
            } while result == -1 && errno == EINTR

            let status = result == pid ? Self.exitStatus(from: rawStatus) : 1
            termination.resolve(status)
        }
    }

    private func waitForExit(timeout: TimeInterval) async -> Int32? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while self.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return self.terminationStatus
    }

    private func waitForTerminationStatus(timeout: TimeInterval) async -> Int32? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while self.terminationStatus == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return self.terminationStatus
    }

    private func waitForResidualProcessesExit(
        _ processIdentities: Set<TTYProcessTreeTerminator.ProcessIdentity>,
        timeout: TimeInterval) async -> Bool
    {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Date() < deadline {
            guard processIdentities.contains(where: TTYProcessTreeTerminator.isCurrent(_:)) else {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !processIdentities.contains(where: TTYProcessTreeTerminator.isCurrent(_:))
    }

    private func currentResidualProcessIdentities(
        includeDescendants: Bool) -> Set<TTYProcessTreeTerminator.ProcessIdentity>
    {
        var identities = self.currentOutputHolderIdentities()
        identities.formUnion(self.observedProcessGroupMembers.snapshot)
        if includeDescendants {
            identities.formUnion(
                TTYProcessTreeTerminator.descendantPIDs(of: self.pid)
                    .compactMap(TTYProcessTreeTerminator.processIdentity(for:)))
        }
        return identities
    }

    private func currentOutputHolderIdentities() -> Set<TTYProcessTreeTerminator.ProcessIdentity> {
        let excludedPIDs: Set<pid_t> = [getpid(), self.pid]
        var holderPIDs = OutputPipeIdentity.holderPIDs(for: self.outputPipes)
        holderPIDs.formUnion(OutputTTYIdentity.holderPIDs(for: self.outputTTYs))
        return Set(holderPIDs.subtracting(excludedPIDs).compactMap(TTYProcessTreeTerminator.processIdentity(for:)))
    }

    private func currentProcessGroupMemberIdentities() -> Set<TTYProcessTreeTerminator.ProcessIdentity> {
        if self.termination.hasObservedExit, self.termination.value == nil {
            let identities = Self.processGroupMemberIdentities(
                processGroup: self.processGroup,
                excluding: self.pid)
            self.observedProcessGroupMembers.formUnion(identities)
            return identities
        }

        guard let rootIdentity = self.rootIdentity
        else {
            return []
        }

        let identities = Self.processGroupMemberIdentities(
            processGroup: self.processGroup,
            rootIdentity: rootIdentity,
            excluding: self.pid)
        self.observedProcessGroupMembers.formUnion(identities)
        return identities
    }

    private static func processGroupMemberIdentities(
        processGroup: pid_t,
        rootIdentity: TTYProcessTreeTerminator.ProcessIdentity,
        excluding excludedPID: pid_t)
        -> Set<TTYProcessTreeTerminator.ProcessIdentity>
    {
        guard TTYProcessTreeTerminator.isCurrent(rootIdentity) else { return [] }

        let identities = Self.processGroupMemberIdentities(
            processGroup: processGroup,
            excluding: excludedPID)
        guard TTYProcessTreeTerminator.isCurrent(rootIdentity) else { return [] }
        return identities
    }

    private static func processGroupMemberIdentities(
        processGroup: pid_t,
        excluding excludedPID: pid_t)
        -> Set<TTYProcessTreeTerminator.ProcessIdentity>
    {
        Set(self.processIDs(inProcessGroup: processGroup)
            .compactMap { pid -> TTYProcessTreeTerminator.ProcessIdentity? in
                guard pid != getpid(),
                      pid != excludedPID,
                      let identity = TTYProcessTreeTerminator.processIdentity(for: pid),
                      getpgid(pid) == processGroup,
                      TTYProcessTreeTerminator.isCurrent(identity)
                else {
                    return nil
                }
                return identity
            })
    }

    private static func processGroupExists(_ processGroup: pid_t) -> Bool {
        errno = 0
        return kill(-processGroup, 0) == 0 || errno == EPERM
    }

    private static func signal(
        processIdentities: Set<TTYProcessTreeTerminator.ProcessIdentity>,
        signal: Int32)
    {
        for identity in processIdentities where TTYProcessTreeTerminator.isCurrent(identity) {
            _ = kill(identity.pid, signal)
        }
    }

    package static func pipeDescriptorsToClose(_ descriptors: [Int32]) -> [Int32] {
        Array(Set(descriptors.filter { $0 > STDERR_FILENO })).sorted()
    }

    private static func exitStatus(from rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7F
        return signal == 0 ? (rawStatus >> 8) & 0xFF : signal
    }
}
