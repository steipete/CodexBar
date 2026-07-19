#!/usr/bin/env swift

import Foundation

struct SurveyOptions {
    var root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
    var days: Double = 30
}

struct Survey {
    var files = 0
    var totalBytes: Int64 = 0
    var lines = 0
    var relevantLines = 0
    var lineLengths: [Int] = []
    var linesOver32KiB = 0
    var linesOver256KiB = 0
    var turnContextLines = 0
    var turnContextOver32KiB = 0
    var turnContextOver256KiB = 0
    var turnContextModelOffsets: [Int] = []
    var turnContextModelOffsetUnder32KiB = 0
    var turnContextModelOffsetUnder256KiB = 0
    var tokenCountLines = 0
    var tokenCountMissingExplicitModel = 0

    mutating func recordFile(byteCount: Int64) {
        self.files += 1
        self.totalBytes += byteCount
    }

    mutating func recordLine(_ line: Data) {
        guard !line.isEmpty else { return }

        let length = line.count
        self.lines += 1
        self.lineLengths.append(length)
        if length > 32 * 1024 {
            self.linesOver32KiB += 1
        }
        if length > 256 * 1024 {
            self.linesOver256KiB += 1
        }

        let isRelevant = line.contains(Marker.eventMessage)
            || line.contains(Marker.turnContext)
            || line.contains(Marker.sessionMetadata)
        if isRelevant {
            self.relevantLines += 1
        }

        if line.contains(Marker.turnContext) {
            self.turnContextLines += 1
            if length > 32 * 1024 {
                self.turnContextOver32KiB += 1
            }
            if length > 256 * 1024 {
                self.turnContextOver256KiB += 1
            }
            if let offset = line.firstOffset(of: Marker.modelField)
                ?? line.firstOffset(of: Marker.modelNameField)
            {
                self.turnContextModelOffsets.append(offset)
                if offset < 32 * 1024 {
                    self.turnContextModelOffsetUnder32KiB += 1
                }
                if offset < 256 * 1024 {
                    self.turnContextModelOffsetUnder256KiB += 1
                }
            }
        }

        if line.contains(Marker.tokenCount) {
            self.tokenCountLines += 1
            if !line.contains(Marker.modelField), !line.contains(Marker.modelNameField) {
                self.tokenCountMissingExplicitModel += 1
            }
        }
    }
}

enum Marker {
    static let eventMessage = Data(#""type":"event_msg""#.utf8)
    static let turnContext = Data(#""type":"turn_context""#.utf8)
    static let sessionMetadata = Data(#""type":"session_meta""#.utf8)
    static let tokenCount = Data(#""token_count""#.utf8)
    static let modelField = Data(#""model""#.utf8)
    static let modelNameField = Data(#""model_name""#.utf8)
}

extension Data {
    func contains(_ marker: Data) -> Bool {
        self.range(of: marker) != nil
    }

    func firstOffset(of marker: Data) -> Int? {
        guard let range = self.range(of: marker) else { return nil }
        return self.distance(from: self.startIndex, to: range.lowerBound)
    }
}

func parseOptions(arguments: [String]) throws -> SurveyOptions {
    var options = SurveyOptions()
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--root":
            index += 1
            guard index < arguments.count else {
                throw UsageError.message("--root requires a path")
            }
            options.root = URL(fileURLWithPath: expandTilde(arguments[index]), isDirectory: true)
        case "--days":
            index += 1
            guard index < arguments.count, let days = Double(arguments[index]) else {
                throw UsageError.message("--days requires a number")
            }
            options.days = days
        case "--help", "-h":
            printUsage()
            Foundation.exit(0)
        default:
            throw UsageError.message("unknown argument: \(arguments[index])")
        }
        index += 1
    }
    return options
}

func expandTilde(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" {
        return home
    }
    return home + String(path.dropFirst())
}

enum UsageError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(text):
            text
        }
    }
}

func printUsage() {
    print(
        """
        Usage: Scripts/cost_jsonl_shape_survey.swift [--root PATH] [--days N]

        Scans local Codex JSONL logs and prints aggregate shape only. It does not
        print prompts, tool payloads, model values, file paths, or raw log lines.
        """)
}

func jsonlFiles(root: URL, modifiedSince cutoff: Date) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
        options: [.skipsHiddenFiles]) else { return [] }

    var files: [URL] = []
    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension == "jsonl" else { continue }
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        guard values?.isRegularFile == true else { continue }
        guard let modifiedAt = values?.contentModificationDate, modifiedAt >= cutoff else { continue }
        files.append(fileURL)
    }
    return files.sorted { $0.path < $1.path }
}

func validateRoot(_ root: URL) throws {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
    guard exists, isDirectory.boolValue else {
        throw UsageError.message("root does not exist or is not a directory")
    }
}

func scan(fileURL: URL, into survey: inout Survey) throws {
    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
    survey.recordFile(byteCount: Int64(values.fileSize ?? 0))

    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }

    var current = Data()
    current.reserveCapacity(4 * 1024)

    while true {
        let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
        if chunk.isEmpty {
            survey.recordLine(current)
            break
        }

        var segmentStart = chunk.startIndex
        while let newline = chunk[segmentStart...].firstIndex(of: 0x0A) {
            current.append(contentsOf: chunk[segmentStart..<newline])
            survey.recordLine(current)
            current.removeAll(keepingCapacity: true)
            segmentStart = chunk.index(after: newline)
        }

        if segmentStart < chunk.endIndex {
            current.append(contentsOf: chunk[segmentStart..<chunk.endIndex])
        }
    }
}

func percentile(_ values: [Int], _ percentile: Double) -> Int {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = Int((percentile * Double(sorted.count - 1)).rounded())
    return sorted[max(0, min(index, sorted.count - 1))]
}

func printSummary(_ survey: Survey, options: SurveyOptions) {
    print("root: \(redactedRootDescription(options.root))")
    print("window days: \(Int(options.days))")
    print("files: \(survey.files)")
    print("total bytes: \(survey.totalBytes)")
    print("lines: \(survey.lines)")
    print("relevant Codex scanner lines: \(survey.relevantLines)")
    print(
        "line length p50/p90/p95/p99/max: " +
            "\(percentile(survey.lineLengths, 0.50)) / " +
            "\(percentile(survey.lineLengths, 0.90)) / " +
            "\(percentile(survey.lineLengths, 0.95)) / " +
            "\(percentile(survey.lineLengths, 0.99)) / " +
            "\(percentile(survey.lineLengths, 1.00)) bytes")
    print("lines > 32 KiB: \(survey.linesOver32KiB)")
    print("lines > 256 KiB: \(survey.linesOver256KiB)")
    print("turn_context lines: \(survey.turnContextLines)")
    print("turn_context lines > 32 KiB: \(survey.turnContextOver32KiB)")
    print("turn_context lines > 256 KiB: \(survey.turnContextOver256KiB)")
    print(
        "turn_context model offset p50/p95/max: " +
            "\(percentile(survey.turnContextModelOffsets, 0.50)) / " +
            "\(percentile(survey.turnContextModelOffsets, 0.95)) / " +
            "\(percentile(survey.turnContextModelOffsets, 1.00)) bytes")
    print(
        "turn_context model offset < 32 KiB: " +
            "\(survey.turnContextModelOffsetUnder32KiB) / \(survey.turnContextLines)")
    print(
        "turn_context model offset < 256 KiB: " +
            "\(survey.turnContextModelOffsetUnder256KiB) / \(survey.turnContextLines)")
    print(
        "token_count rows missing an explicit model: " +
            "\(survey.tokenCountMissingExplicitModel) / \(survey.tokenCountLines)")
}

func redactedRootDescription(_ root: URL) -> String {
    let defaultRoot = SurveyOptions().root.standardizedFileURL.path
    let currentRoot = root.standardizedFileURL.path
    if currentRoot == defaultRoot {
        return "default Codex sessions"
    }
    return "custom root (redacted)"
}

do {
    let options = try parseOptions(arguments: CommandLine.arguments)
    try validateRoot(options.root)
    let cutoff = Date().addingTimeInterval(-options.days * 24 * 60 * 60)
    let files = jsonlFiles(root: options.root, modifiedSince: cutoff)
    guard !files.isEmpty else {
        throw UsageError.message("no .jsonl files found in the selected time window")
    }
    var survey = Survey()
    for fileURL in files {
        try scan(fileURL: fileURL, into: &survey)
    }
    printSummary(survey, options: options)
} catch let error as UsageError {
    fputs("error: \(error.description)\n\n", stderr)
    printUsage()
    Foundation.exit(2)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    Foundation.exit(1)
}
