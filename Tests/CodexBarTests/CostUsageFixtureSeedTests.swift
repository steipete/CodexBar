import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing

struct CostUsageFixtureSeedTests {
    @Test
    func `initial seeds match atomic fixture bytes paths and file counts`() throws {
        let env = try CostUsageTestEnvironment()
        let reference = try CostUsageTestEnvironment()
        defer {
            env.cleanup()
            reference.cleanup()
        }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let contents = ["", "{\"message\":\"café 🦞\"}\n", "first\u{0}second\nlast\n"]
        var urls: [URL] = []
        for (index, body) in contents.enumerated() {
            let filename = "session-\(index).jsonl"
            let seeded = try env.seedCodexSessionFile(day: day, filename: filename, contents: body)
            let atomic = try reference.writeCodexSessionFile(day: day, filename: filename, contents: body)
            #expect(seeded.path == env.codexSessionsRoot.appendingPathComponent("2026/05/10/\(filename)").path)
            #expect(try Data(contentsOf: seeded) == Data(body.utf8))
            #expect(try Data(contentsOf: seeded) == Data(contentsOf: atomic))
            urls.append(seeded)
        }
        let directory = try #require(urls.first).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(Set(files.map(\.lastPathComponent)) == Set(urls.map(\.lastPathComponent)))
        #expect(files.count == contents.count)
    }

    @Test(arguments: ["file", "directory", "symlink"])
    func `initial seeds reject existing paths without overwriting them`(kind: String) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let original = try env.writeCodexSessionFile(day: day, filename: "original.jsonl", contents: "original\n")
        let destination = original.deletingLastPathComponent().appendingPathComponent("existing.jsonl")
        switch kind {
        case "file":
            try FileManager.default.copyItem(at: original, to: destination)
        case "directory":
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        default:
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: original)
        }
        do {
            _ = try env.seedCodexSessionFile(day: day, filename: destination.lastPathComponent, contents: "replacement")
            Issue.record("Initial corpus seeding must reject an existing path")
        } catch {
            #expect((error as NSError).domain == NSPOSIXErrorDomain)
            #expect((error as NSError).code == Int(EEXIST))
        }
        #expect(try Data(contentsOf: original) == Data("original\n".utf8))
        if kind == "file" || kind == "symlink" {
            #expect(try Data(contentsOf: destination) == Data("original\n".utf8))
        }
        if kind == "symlink" {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == original.path)
        }
    }

    @Test
    func `initial seed and atomic writer propagate the same day directory errors`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let blocker = env.codexSessionsRoot.appendingPathComponent("2026")
        #expect(FileManager.default.createFile(atPath: blocker.path, contents: Data("blocker".utf8)))
        let writers: [(Date, String, String) throws -> URL] = [env.writeCodexSessionFile, env.seedCodexSessionFile]
        var errors: [NSError] = []
        for writer in writers {
            do {
                _ = try writer(day, "session.jsonl", "body")
                Issue.record("Creating a day directory beneath a file must fail")
            } catch {
                errors.append(error as NSError)
            }
        }
        #expect(errors.count == 2)
        #expect(errors.first?.domain == errors.last?.domain)
        #expect(errors.first?.code == errors.last?.code)
        #expect(try Data(contentsOf: blocker) == Data("blocker".utf8))
    }

    @Test
    func `shared atomic fixture writer still replaces an existing file`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let original = try env.writeCodexSessionFile(day: day, filename: "session.jsonl", contents: "before")
        let inode = try FileManager.default.attributesOfItem(atPath: original.path)[.systemFileNumber] as? NSNumber
        let replacement = try env.writeCodexSessionFile(day: day, filename: "session.jsonl", contents: "after")
        #expect(replacement == original)
        #expect(try Data(contentsOf: replacement) == Data("after".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: replacement.path)
        #expect(attributes[.systemFileNumber] as? NSNumber != inode)
    }
}
