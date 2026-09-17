#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

extension CodexRemoteLogMirror {
    /// A caller must withhold a combined result when configuration bytes cannot be verified.
    public static let unavailableConfigurationFingerprint = "ssh-configuration-unavailable"

    /// Hashes bounded primary and directly included configuration contents, without invoking SSH.
    /// IdentityFile paths are never followed. A misdirected Include of a private-key file is rejected
    /// from its format header before key payload is read. Missing files have explicit empty revisions;
    /// unreadable, non-regular, oversized, invalid UTF-8 or unstable files return the unavailable sentinel.
    /// Match exec, canonicalization, DNS, agent state, dynamic and nested Includes remain outside this
    /// local revision; it is not an effective SSH configuration resolver.
    public static func configurationFingerprint(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String
    {
        self.configurationFingerprint(environment: environment, readConfig: self.readConfigurationContents)
    }

    static func configurationFingerprint(
        environment: [String: String],
        readConfig: (URL) throws -> Data?) -> String
    {
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let userRoot = home.appendingPathComponent(".ssh", isDirectory: true)
        var primary = [userRoot.appendingPathComponent("config"), URL(fileURLWithPath: "/etc/ssh/ssh_config")]
        #if DEBUG
        if let file = environment["CODEXBAR_SSH_CONFIG_FILE"], file.hasPrefix("/"),
           CodexRemoteLogSource.validHome(file)
        {
            primary[0] = URL(fileURLWithPath: file)
        }
        #endif
        do {
            var revisions: [String] = []
            var totalBytes = 0
            func record(_ file: URL) throws -> String? {
                guard let data = try readConfig(file) else {
                    revisions.append(file.path + ":missing")
                    return nil
                }
                guard data.count <= 1024 * 1024, data.count <= 8 * 1024 * 1024 - totalBytes,
                      let text = String(data: data, encoding: .utf8), !data.contains(0)
                else { throw ConfigurationReadError.unverifiable }
                totalBytes += data.count
                revisions.append(file.path + ":" + CodexRemoteLogManifest.digest(data))
                return text
            }
            for file in primary {
                guard let text = try record(file) else { continue }
                // Include is accepted inside Host/Match blocks; follow only this direct config level.
                for line in text.split(whereSeparator: \.isNewline) {
                    let pieces = self.configurationWords(String(line))
                    guard pieces.first?.lowercased() == "include" else { continue }
                    for include in pieces.dropFirst() {
                        guard !include.contains("%"), !include.contains("$"), !include.contains(".."),
                              !include.contains("["), !include.contains("]"), !include.contains("\\"),
                              !include.hasPrefix("~") || include.hasPrefix("~/")
                        else { throw ConfigurationReadError.unverifiable }
                        let path: String
                        if include.hasPrefix("~/") {
                            path = home.appendingPathComponent(String(include.dropFirst(2))).path
                        } else if include.hasPrefix("/") {
                            path = include
                        } else {
                            let base = file == primary[0] ? userRoot : URL(fileURLWithPath: "/etc/ssh")
                            path = base.appendingPathComponent(include).path
                        }
                        let included = try self.includedConfigurationFiles(path)
                        revisions.append("include:\(path):\(included.count)")
                        for includedFile in included {
                            _ = try record(includedFile)
                        }
                    }
                }
            }
            return CodexRemoteLogManifest.digest(Data(revisions.sorted().joined(separator: "\0").utf8))
        } catch {
            return self.unavailableConfigurationFingerprint
        }
    }

    static func configurationWords(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted: Character?
        for char in line {
            if let quote = quoted {
                if char == quote { quoted = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quoted = char
            } else if char == "#" {
                break
            } else if char.isWhitespace || char == "=" {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private enum ConfigurationReadError: Error { case unverifiable }

    private static func includedConfigurationFiles(_ pattern: String) throws -> [URL] {
        let url = URL(fileURLWithPath: pattern)
        guard pattern.contains("*") || pattern.contains("?") else { return [url] }
        let parent = url.deletingLastPathComponent()
        guard !parent.path.contains("*"), !parent.path.contains("?") else {
            throw ConfigurationReadError.unverifiable
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        let wildcard = url.lastPathComponent
        let matched = names.filter { name in
            name.range(
                of: "^" + NSRegularExpression.escapedPattern(for: wildcard)
                    .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$",
                options: .regularExpression) != nil
        }.sorted()
        guard matched.count <= 4096 else { throw ConfigurationReadError.unverifiable }
        return matched.map { parent.appendingPathComponent($0) }
    }

    static func readConfigurationContents(_ url: URL) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ConfigurationReadError.unverifiable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        let limit = 1024 * 1024
        guard fstat(descriptor, &before) == 0, CodexRemoteLogStorage.isRegular(before),
              before.st_size >= 0, before.st_size <= limit
        else { throw ConfigurationReadError.unverifiable }
        // Inspect only the textual format header before any private-key body could be read.
        var data = Data()
        while data.count < min(Int(before.st_size), 512) {
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else { break }
            guard byte.first != 0 else { throw ConfigurationReadError.unverifiable }
            data.append(byte)
            if byte.first == 10 { break }
        }
        let header = String(data: data, encoding: .utf8) ?? ""
        guard !(header.hasPrefix("-----BEGIN ") && header.contains("PRIVATE KEY-----")),
              !header.hasPrefix("PuTTY-User-Key-File-"),
              !header.hasPrefix("---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----")
        else { throw ConfigurationReadError.unverifiable }
        while let bytes = try handle.read(upToCount: min(65536, limit - data.count + 1)), !bytes.isEmpty {
            data.append(bytes)
            guard data.count <= limit else { throw ConfigurationReadError.unverifiable }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, data.count == before.st_size,
              self.configurationMetadataMatches(before, after),
              String(data: data, encoding: .utf8) != nil, !data.contains(0)
        else { throw ConfigurationReadError.unverifiable }
        return data
    }

    private static func configurationMetadataMatches(_ before: stat, _ after: stat) -> Bool {
        guard before.st_ino == after.st_ino, before.st_dev == after.st_dev, before.st_size == after.st_size else {
            return false
        }
        #if canImport(Darwin)
        return before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        #else
        return before.st_mtim.tv_sec == after.st_mtim.tv_sec && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec &&
            before.st_ctim.tv_sec == after.st_ctim.tv_sec && before.st_ctim.tv_nsec == after.st_ctim.tv_nsec
        #endif
    }
}
