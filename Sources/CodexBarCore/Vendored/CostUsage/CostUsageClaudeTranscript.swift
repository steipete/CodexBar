import Foundation

extension CostUsageScanner {
    /// logrotate may keep session.jsonl.1 before compressing it as session.jsonl.1.gz.
    static func claudeTranscriptName(_ url: URL) -> URL? {
        var name = url
        if name.pathExtension.lowercased() == "gz" { name.deletePathExtension() }
        let suffix = name.pathExtension
        if !suffix.isEmpty, suffix.utf8.allSatisfy({ (48...57).contains($0) }) { name.deletePathExtension() }
        return name.pathExtension.lowercased() == "jsonl" ? name : nil
    }

    /// Stream gzip through the same JSONL reader as a plain file. No decompressed mirror is created.
    static func withClaudeTranscript<T>(_ url: URL, read: (URL) throws -> T) throws -> T {
        guard url.pathExtension.lowercased() == "gz" else { return try read(url) }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let pipe = Pipe()
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-dc"]
        gzip.environment = [:]
        gzip.standardInput = input
        gzip.standardOutput = pipe
        gzip.standardError = FileHandle.nullDevice
        try gzip.run()
        defer {
            try? pipe.fileHandleForReading.close()
            gzip.waitUntilExit()
        }
        let stream = URL(fileURLWithPath: "/dev/fd/\(pipe.fileHandleForReading.fileDescriptor)")
        let result = try read(stream)
        try pipe.fileHandleForReading.close()
        gzip.waitUntilExit()
        guard gzip.terminationReason == .exit, gzip.terminationStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }
}
