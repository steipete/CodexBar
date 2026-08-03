import Foundation

enum DarwinProcessEnumerator {
    /// Keep this predicate a superset of every executable path that
    /// `AntigravityStatusProbe.antigravityProcessKind` can classify. The Darwin
    /// process scan uses it before requesting the more privacy-sensitive argv.
    static func isAntigravityCandidatePath(_ executablePath: String) -> Bool {
        let lowercasedPath = executablePath.lowercased()
        if lowercasedPath.contains("antigravity") {
            return true
        }

        var basename = URL(fileURLWithPath: lowercasedPath).lastPathComponent
        if basename.hasSuffix(".exe") {
            basename.removeLast(4)
        }
        return basename.hasPrefix("language_server") ||
            basename.hasPrefix("language-server") ||
            ["agy", "antigravity-cli", "antigravity_cli", "node", "bun"].contains(basename)
    }

    /// Parses the `KERN_PROCARGS2` payload without consuming the environment
    /// strings that follow argv.
    static func parseProcArgs2(_ data: Data) -> String? {
        let argumentCountSize = MemoryLayout<Int32>.size
        guard data.count >= argumentCountSize else { return nil }
        let argumentCount = data.withUnsafeBytes { rawBuffer in
            Int(Int32(littleEndian: rawBuffer.loadUnaligned(as: Int32.self)))
        }
        guard argumentCount >= 0 else { return nil }

        let bytes = [UInt8](data)
        var offset = argumentCountSize
        guard let executableTerminator = bytes[offset...].firstIndex(of: 0) else { return nil }
        offset = executableTerminator + 1
        while offset < bytes.count, bytes[offset] == 0 {
            offset += 1
        }

        var arguments: [String] = []
        arguments.reserveCapacity(argumentCount)
        for _ in 0..<argumentCount {
            guard offset < bytes.count,
                  let terminator = bytes[offset...].firstIndex(of: 0),
                  let argument = String(bytes: bytes[offset..<terminator], encoding: .utf8)
            else { return nil }
            arguments.append(argument)
            offset = terminator + 1
        }
        return arguments.joined(separator: " ")
    }
}

#if canImport(Darwin)
import Darwin

extension DarwinProcessEnumerator {
    static func allPIDs() -> [Int32] {
        let requiredCount = proc_listallpids(nil, 0)
        guard requiredCount > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(requiredCount) + 32)
        let actualCount = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard actualCount > 0 else { return [] }
        return Array(pids.prefix(Int(actualCount))).filter { $0 > 0 }
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let byteCount = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_pidpath(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
        }
        guard byteCount > 0 else { return nil }
        return buffer.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let bytes = UnsafeRawBufferPointer(start: baseAddress, count: Int(byteCount))
            let pathBytes = bytes.prefix { $0 != 0 }
            guard !pathBytes.isEmpty else { return nil }
            return String(bytes: pathBytes, encoding: .utf8)
        }
    }

    static func bsdInfo(pid: Int32) -> (ppid: Int32, startTime: Date)? {
        var info = proc_bsdinfo()
        let byteCount = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size))
        guard byteCount == MemoryLayout<proc_bsdinfo>.size else { return nil }
        let startInterval = TimeInterval(info.pbi_start_tvsec) +
            TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return (Int32(bitPattern: info.pbi_ppid), Date(timeIntervalSince1970: startInterval))
    }

    static func commandLine(pid: Int32) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var byteCount = 0
        guard sysctl(&mib, u_int(mib.count), nil, &byteCount, nil, 0) == 0,
              byteCount >= MemoryLayout<Int32>.size
        else { return nil }

        var data = Data(count: byteCount)
        let result = data.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &byteCount, nil, 0)
        }
        guard result == 0 else { return nil }
        if byteCount < data.count {
            data.removeSubrange(byteCount..<data.count)
        }
        return self.parseProcArgs2(data)
    }

    static func currentWorkingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let byteCount = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard byteCount == MemoryLayout<proc_vnodepathinfo>.size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { rawBuffer in
            let pathBytes = rawBuffer.prefix { $0 != 0 }
            guard !pathBytes.isEmpty else { return nil }
            return String(bytes: pathBytes, encoding: .utf8)
        }
    }

    static func listeningTCPPorts(pid: Int32) -> [Int] {
        let requiredBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard requiredBytes > 0 else { return [] }
        let descriptorStride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(requiredBytes) / descriptorStride + 8)
        let actualBytes = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(
                pid,
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count))
        }
        guard actualBytes > 0 else { return [] }

        var ports: Set<Int> = []
        for descriptor in descriptors.prefix(Int(actualBytes) / descriptorStride)
            where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET
        {
            var info = socket_fdinfo()
            let byteCount = proc_pidfdinfo(
                pid,
                descriptor.proc_fd,
                PROC_PIDFDSOCKETINFO,
                &info,
                Int32(MemoryLayout<socket_fdinfo>.size))
            guard byteCount == MemoryLayout<socket_fdinfo>.size,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { continue }
            let networkPort = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            ports.insert(Int(UInt16(bigEndian: networkPort)))
        }
        return ports.sorted()
    }
}
#endif
