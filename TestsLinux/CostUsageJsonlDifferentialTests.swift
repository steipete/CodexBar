import Foundation
import Testing
@testable import CodexBarCore

/// Bounded default-suite subset of the synthetic LF-span investigation; no timing assertions.
private let jsonlSmallStrings = [
    "",
    "\n",
    "\n\n",
    "\r",
    "\r\n",
    "x\n",
    "{}",
    "{}\n",
    "[]",
    "[]\r\n\n{}",
    "{\"x\":\"a\\\"b\\\\c{[}]\"}",
    "{\"x\":\"a\\u1234\"}",
    "{\"x\":\"a\\u12",
    "{\"x\":\"abc\\",
    "{\"x\":[1,{\"y\":2}]}",
    "{}junk",
    "{]",
    "{{}}",
    "]}",
    "true",
    "tru",
    "false",
    "fals",
    "null",
    "nul",
    "true ",
    "truex",
    "0",
    "-",
    "-0",
    "12",
    "12 ",
    "1.",
    "1.2",
    "1e",
    "1e-",
    "1e+2",
    "1e2 ",
    "01",
    "\"str\"",
    "\"str",
    " \t\r",
    " \ttrue\r",
    "{\"u\":\"é🦞é\"}\r\n",
    "{}\n{\"partial\":",
    "\n[1]\nfalse\n3\n",
]
private let jsonlConfigurations = [(-1, -1), (0, 0), (1, 0), (0, 1), (2, 7), (7, 2), (64, 64), (Int.max, Int.max)]

/// Yield between bounded batches so oracle scans share the executor without interrupting comparisons.
struct CostUsageJsonlDifferentialTests {
    @Test
    func `all short byte splits and persisted resumes match the frozen scalar scanner`() async throws {
        let fixture = try JsonlParityFixture()
        defer { fixture.remove() }
        let file = fixture.file
        let inputs = jsonlSmallStrings.map { Data($0.utf8) } + [
            Data([0, 255, 13, 10, 34, 255, 34]),
            Data([123, 10, 125, 10, 10, 0, 10]),
        ]
        for (i, data) in inputs.enumerated() {
            try data.write(to: file)
            for (maximum, prefix) in jsonlConfigurations {
                for split in 0...data.count {
                    let first = try fixture.compare("all-short-byte-splits: " + "\(i)/\(maximum)/\(prefix)/\(split)") {
                        runJsonlParity($0, file, maximum: maximum, prefix: prefix, budget: Int64(split))
                    }
                    _ = try fixture.compare("cross-version-resume: " + "\(i)/\(split)") {
                        runJsonlParity(
                            $0,
                            file,
                            offset: first.committed ?? 0,
                            maximum: maximum,
                            prefix: prefix,
                            resume: first.resume)
                    }
                }
                for budget: Int64 in [-1, Int64.min, Int64.max] {
                    _ = try fixture.compare("signed-budget-edges: " + "\(i)/\(budget)") {
                        runJsonlParity($0, file, maximum: maximum, prefix: prefix, budget: budget)
                    }
                }
                await Task.yield()
            }
            for split in 0...data.count {
                let part = Data(data.prefix(split))
                let first = try fixture.compare("append-initial-eof: " + "\(i)/\(split)") { variant in
                    try part.write(to: file)
                    return runJsonlParity(variant, file, maximum: 7, prefix: 7)
                }
                _ = try fixture.compare("append-resume: " + "\(i)/\(split)") { variant in
                    try data.write(to: file)
                    return runJsonlParity(
                        variant,
                        file,
                        offset: first.committed ?? 0,
                        maximum: 7,
                        prefix: 7,
                        resume: first.resume)
                }
            }
            try data.write(to: file)
            for offset in [-1, 0, 1, data.count, data.count + 7] {
                _ = try fixture.compare("offset-edges: " + "\(i)/\(offset)") { runJsonlParity(
                    $0,
                    file,
                    offset: Int64(offset)) }
            }
            await Task.yield()
        }
        print("JSONL differential comparisons: \(fixture.comparisons)")
    }

    @Test
    func `chunk thresholds cancellation and file mutations match the frozen scalar scanner`() async throws {
        let fixture = try JsonlParityFixture()
        defer { fixture.remove() }
        let file = fixture.file
        let chunk = 256 * 1024
        let sizes = [chunk - 1, chunk, chunk + 1, 2 * chunk + 1]
        for length in sizes {
            // The first LF falls immediately before, at, or after a read boundary.
            let text = "{\"body\":\"" + String(repeating: "x", count: length - 12) + "\"}\r\n\n{\"next\":true}\n{\"partial\":\"\\u12"
            let data = Data(text.utf8)
            try data.write(to: file)
            let splits = Array(Set([chunk - 1, chunk, chunk + 1, data.count])).sorted()
            for (maximum, prefix) in [(524_288, 64), (64, 524_288), (0, 0)] {
                for split in splits {
                    let first = try fixture
                        .compare("chunk-prefix-budget-edges: " + "\(length)/\(split)/\(maximum)/\(prefix)") {
                            runJsonlParity($0, file, maximum: maximum, prefix: prefix, budget: Int64(split))
                        }
                    _ = try fixture.compare("chunk-cross-resume: " + "\(length)/\(split)") {
                        runJsonlParity(
                            $0,
                            file,
                            offset: first.committed ?? 0,
                            maximum: maximum,
                            prefix: prefix,
                            resume: first.resume)
                    }
                    await Task.yield()
                }
            }
            for stop in 1...4 {
                let first = try fixture.compare("should-stop-chunks: " + "\(length)/\(stop)") { runJsonlParity(
                    $0,
                    file,
                    stopAt: stop) }
                _ = try fixture.compare("should-stop-resume: " + "\(length)/\(stop)") {
                    runJsonlParity($0, file, offset: first.committed ?? 0, resume: first.resume)
                }
                await Task.yield()
            }
            _ = try fixture.compare("should-stop-after-line: " + "\(length)") { runJsonlParity(
                $0,
                file,
                stopAfterLine: true) }
            let normal = runJsonlParity(.scalar, file)
            let checkCount = normal.events.count(where: { $0.hasPrefix("check:") })
            await Task.yield()
            for cancel in 1...(checkCount + 1) {
                _ = try fixture.compare("cancellation-every-callback: " + "\(length)/\(cancel)") { runJsonlParity(
                    $0,
                    file,
                    cancelAt: cancel) }
                await Task.yield()
            }
            _ = try fixture.compare("cancellation-after-line: " + "\(length)") { runJsonlParity(
                $0,
                file,
                cancelAfterLine: true) }
            let partial = runJsonlParity(.scalar, file, prefix: 64, budget: Int64(chunk - 1))
            await Task.yield()
            for replacement in [Data(), Data("{}\n".utf8), data.prefix(chunk + 2)] {
                _ = try fixture.compare("truncate-between-resumes: " + "\(length)/\(replacement.count)") { variant in
                    try replacement.write(to: file)
                    return runJsonlParity(
                        variant,
                        file,
                        offset: partial.committed ?? 0,
                        prefix: 64,
                        resume: partial.resume)
                }
                await Task.yield()
            }
            // Active scan mutations are synthetic and occur at a known existing cancellation boundary.
            for mutation in ["append", "truncate"] {
                _ = try fixture.compare("mutation-during-scan: " + "\(length)/\(mutation)") { variant in
                    try data.write(to: file)
                    return runJsonlParity(variant, file, action: { check in
                        if check == 3 {
                            let handle = try FileHandle(forWritingTo: file)
                            defer { try? handle.close() }
                            if mutation == "append" {
                                try handle.seekToEnd()
                                try handle.write(contentsOf: Data("34\"}\n".utf8))
                            } else {
                                try handle.truncate(atOffset: 0)
                            }
                        }
                    })
                }
                await Task.yield()
            }
        }
        print("JSONL differential comparisons: \(fixture.comparisons)")
    }

    @Test
    func `EOF stop precedence and file errors match the frozen scalar scanner`() async throws {
        let fixture = try JsonlParityFixture()
        defer { fixture.remove() }
        let file = fixture.file
        let chunk = 256 * 1024
        for file in [fixture.root.appendingPathComponent("does-not-exist.jsonl"), fixture.root] {
            let result = try fixture.compare("open-read-errors: " + file.lastPathComponent) { runJsonlParity($0, file) }
            #expect(result.failure != nil)
        }
        try Data("{}".utf8).write(to: file)
        // Filesystems can reject Int64.max; preserve exact error/state parity rather than require success.
        _ = try fixture.compare("maximum-offset: Int64.max") { runJsonlParity(
            $0,
            file,
            offset: Int64.max,
            budget: 0) }
        let supportedOffset = try fixture.compare("supported-eof-offset") { runJsonlParity(
            $0,
            file,
            offset: 2,
            budget: 0) }
        #expect(supportedOffset.failure == nil)
        #expect(supportedOffset.committed == 2)
        #expect(supportedOffset.read == 2)
        // Budget runs ending exactly at complete EOF, and time-stop precedence over EOF commit.
        for suffix in ["{}", "\"ok\"", "true", "12", "12 ", "{", "\"open\\", "tru", "1e-"] {
            let data = Data((String(repeating: " ", count: chunk - 1) + suffix).utf8)
            try data.write(to: file)
            for prefix in [0, 64, chunk * 2] {
                for stop: Int? in [nil, 1, 2] {
                    _ = try fixture.compare("eof-budget-stop-precedence: " + suffix) {
                        runJsonlParity(
                            $0,
                            file,
                            maximum: prefix,
                            prefix: prefix,
                            budget: Int64(data.count),
                            stopAt: stop)
                    }
                }
                await Task.yield()
            }
        }
        print("JSONL differential comparisons: \(fixture.comparisons)")
    }

    @Test
    func `unusual decoded checkpoints retain scalar checked operations`() async throws {
        let fixture = try JsonlParityFixture()
        defer { fixture.remove() }
        let file = fixture.file
        try Data("{".utf8).write(to: file)
        let seedState = try #require(runJsonlParity(.scalar, file).resume)
        for depth in [Int.min, Int.min + 1, -1, 0, Int.max - 4, Int.max - 1, Int.max] {
            for suffix in ["x\n", "}x\n", "\n\nx\n"] {
                // Avoid intentionally crashing the baseline at Int.min minus one.
                if depth == Int.min, suffix.hasPrefix("}") { continue }
                var state = try #require(JSONSerialization.jsonObject(with: seedState) as? [String: Any])
                var tail = try #require(state["jsonTailState"] as? [String: Any])
                tail["containerDepth"] = depth
                state["jsonTailState"] = tail
                state["lineBytes"] = Int.max - 8
                state["truncated"] = true
                state["offset"] = 0
                let encoded = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                try Data(suffix.utf8).write(to: file)
                _ = try fixture.compare("safe-integer-limit-codable-resumes: " + "\(depth)/\(suffix)") {
                    runJsonlParity($0, file, maximum: Int.max, prefix: 64, resume: encoded)
                }
            }
            await Task.yield()
        }
        for literal in ["trueLiteral", "falseLiteral", "nullLiteral"] {
            for matched in [-1, Int.min] {
                for started in [false, true] {
                    var state = try #require(JSONSerialization.jsonObject(with: seedState) as? [String: Any])
                    var tail = try #require(state["jsonTailState"] as? [String: Any])
                    tail["scalarState"] = [literal: ["_0": matched]]
                    tail["sawNonWhitespace"] = started
                    state["jsonTailState"] = tail
                    state["offset"] = 0
                    let encoded = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                    try Data((started ? "\n" : " \tx\n").utf8).write(to: file)
                    let result = try fixture
                        .compare("safe-negative-literal-codable-resumes: " + "\(literal)/\(matched)/\(started)") {
                            runJsonlParity($0, file, resume: encoded)
                        }
                    #expect(result.failure == nil)
                }
            }
            await Task.yield()
        }
        for negativeBytes in [-1, -2, -5, Int.min] {
            for suffix in ["ab\n\" \n{}", "\n\n[]", "xyz\n{}\ntrue ", " ", "\"}", "abc\n\"}"] {
                var state = try #require(JSONSerialization.jsonObject(with: seedState) as? [String: Any])
                state["lineBytes"] = negativeBytes
                state["offset"] = 0
                let encoded = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                try Data(suffix.utf8).write(to: file)
                let result = try fixture
                    .compare("negative-line-byte-codable-resumes: " + "\(negativeBytes)/\(suffix)") {
                        runJsonlParity($0, file, resume: encoded)
                    }
                #expect(result.failure == nil)
            }
            await Task.yield()
        }
        print("JSONL differential comparisons: \(fixture.comparisons)")
    }
}
