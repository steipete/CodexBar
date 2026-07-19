#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Foundation

public struct CodexThreadMetadata: Equatable, Sendable {
    public let title: String?
    public let agentPath: String?

    public init(title: String?, agentPath: String?) {
        self.title = title
        self.agentPath = agentPath
    }
}

public struct CodexThreadMetadataReader: Sendable {
    public let databaseURL: URL
    private let sessionIndexURL: URL?

    public init(
        codexHomeDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolvedWorkingDirectory: URL? = nil,
        fileManager: FileManager = .default)
    {
        let sqliteHomeDirectory = Self.sqliteHomeDirectory(
            codexHomeDirectory: codexHomeDirectory,
            environment: environment,
            resolvedWorkingDirectory: resolvedWorkingDirectory)
        let candidates = (try? fileManager.contentsOfDirectory(
            at: sqliteHomeDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        self.databaseURL = candidates
            .filter { $0.pathExtension == "sqlite" && $0.deletingPathExtension().lastPathComponent.hasPrefix("state_") }
            .max { Self.stateVersion($0) < Self.stateVersion($1) }
            ?? sqliteHomeDirectory.appendingPathComponent("state_5.sqlite")
        self.sessionIndexURL = codexHomeDirectory.appendingPathComponent("session_index.jsonl")
    }

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
        self.sessionIndexURL = nil
    }

    public func metadata(for sessionIDs: Set<String>) -> [String: CodexThreadMetadata] {
        self.metadata(for: sessionIDs, indexedNames: self.sessionIndexNames(for: sessionIDs))
    }

    func metadata(
        for sessionIDs: Set<String>,
        indexedNames: [String: String])
        -> [String: CodexThreadMetadata]
    {
        guard !sessionIDs.isEmpty else { return [:] }
        let scopedIndexedNames = indexedNames.filter { sessionIDs.contains($0.key) }
        var result = scopedIndexedNames.mapValues { CodexThreadMetadata(title: $0, agentPath: nil) }
        #if canImport(SQLite3) || canImport(CSQLite3)
        var database: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else {
            if database != nil {
                sqlite3_close(database)
            }
            return result
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)

        let queries = [
            "SELECT title, agent_path FROM threads WHERE id = ?1 LIMIT 1",
            "SELECT title, NULL FROM threads WHERE id = ?1 LIMIT 1",
        ]
        var statement: OpaquePointer?
        for query in queries where statement == nil {
            if sqlite3_prepare_v2(database, query, -1, &statement, nil) != SQLITE_OK {
                statement = nil
            }
        }
        guard let statement else { return result }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for sessionID in sessionIDs {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, sessionID, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW else { continue }
            let title = scopedIndexedNames[sessionID] ?? Self.string(statement, column: 0)
            let agentPath = Self.string(statement, column: 1)
            if title != nil || agentPath != nil {
                result[sessionID] = CodexThreadMetadata(title: title, agentPath: agentPath)
            }
        }
        return result
        #else
        return result
        #endif
    }

    private func sessionIndexNames(for sessionIDs: Set<String>) -> [String: String] {
        guard let sessionIndexURL else { return [:] }
        return Self.sessionIndexNames(at: sessionIndexURL, for: sessionIDs)
    }

    static func indexedThreadNames(
        codexHomeDirectory: URL,
        sessionIDs: Set<String>)
        -> [String: String]
    {
        guard !sessionIDs.isEmpty else { return [:] }
        return self.sessionIndexNames(
            at: codexHomeDirectory.appendingPathComponent("session_index.jsonl"),
            for: sessionIDs)
    }

    private static func sessionIndexNames(
        at sessionIndexURL: URL,
        for sessionIDs: Set<String>)
        -> [String: String]
    {
        var names: [String: String] = [:]
        _ = try? CostUsageJsonl.scan(
            fileURL: sessionIndexURL,
            maxLineBytes: 64 * 1024,
            prefixBytes: 64 * 1024)
        { line in
            guard !line.wasTruncated,
                  let entry = try? JSONDecoder().decode(SessionIndexEntry.self, from: line.bytes),
                  sessionIDs.contains(entry.id)
            else { return }
            let name = entry.threadName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                names[entry.id] = name
            }
        }
        return names
    }

    private static func stateVersion(_ url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent.dropFirst("state_".count)) ?? 0
    }

    private static func sqliteHomeDirectory(
        codexHomeDirectory: URL,
        environment: [String: String],
        resolvedWorkingDirectory: URL?)
        -> URL
    {
        if let configuredPath = configuredSQLiteHome(
            codexHomeDirectory: codexHomeDirectory)
        {
            return configuredPath
        }

        if let rawPath = environment["CODEX_SQLITE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPath.isEmpty
        {
            let path = rawPath as NSString
            if path.isAbsolutePath {
                return URL(fileURLWithPath: rawPath, isDirectory: true)
            }
            if let resolvedWorkingDirectory {
                return resolvedWorkingDirectory
                    .appendingPathComponent(rawPath, isDirectory: true)
            }
        }

        return codexHomeDirectory
    }

    private static func configuredSQLiteHome(codexHomeDirectory: URL) -> URL? {
        // Only the user config is stable after a rollout is written. Codex can also apply trusted
        // project, managed, profile, and invocation layers, but their effective values are not
        // persisted in rollout metadata and may have changed by the time CodexBar scans it. Do not
        // read arbitrary project config here: an untrusted checkout could redirect us to unrelated
        // files. Explicit names from session_index.jsonl and agent paths persisted in rollouts take
        // precedence; this database lookup is a best-effort title fallback.
        let configURL = codexHomeDirectory.appendingPathComponent("config.toml")
        guard let handle = try? FileHandle(forReadingFrom: configURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024),
              let contents = String(data: data, encoding: .utf8),
              let rawPath = Self.topLevelSQLiteHome(from: contents),
              (rawPath as NSString).isAbsolutePath
        else { return nil }
        return URL(fileURLWithPath: rawPath, isDirectory: true)
    }

    private static func topLevelSQLiteHome(from contents: String) -> String? {
        let lines = contents.components(separatedBy: .newlines)
        var multilineQuote: TOMLMultilineQuote?
        var lineIndex = 0
        while lineIndex < lines.count {
            let rawLine = lines[lineIndex]
            if multilineQuote != nil {
                multilineQuote = Self.multilineQuote(afterScanning: rawLine, startingWith: multilineQuote)
                lineIndex += 1
                continue
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                lineIndex += 1
                continue
            }
            if line.hasPrefix("[") {
                return nil
            }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  Self.tomlKey(String(parts[0])) == "sqlite_home"
            else {
                multilineQuote = Self.multilineQuote(afterScanning: rawLine, startingWith: nil)
                lineIndex += 1
                continue
            }
            return Self.tomlString(String(parts[1]), followingLines: lines.dropFirst(lineIndex + 1))
        }
        return nil
    }

    private static func tomlKey(_ rawKey: String) -> String? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key == "sqlite_home" {
            return key
        }
        return Self.tomlString(key)
    }

    private static func multilineQuote(
        afterScanning line: String,
        startingWith multilineQuote: TOMLMultilineQuote?)
        -> TOMLMultilineQuote?
    {
        let characters = Array(line)
        var state: TOMLScanState = switch multilineQuote {
        case .basic: .multilineBasic
        case .literal: .multilineLiteral
        case nil: .normal
        }
        var index = 0

        while index < characters.count {
            let character = characters[index]
            switch state {
            case .normal:
                Self.advanceNormalTOMLState(characters: characters, state: &state, index: &index)
            case .basic:
                if character == "\\" {
                    index = min(index + 2, characters.count)
                } else {
                    state = character == "\"" ? .normal : .basic
                    index += 1
                }
            case .literal:
                state = character == "'" ? .normal : .literal
                index += 1
            case .multilineBasic:
                if character == "\\" {
                    index = min(index + 2, characters.count)
                } else if Self.hasTripleQuote("\"", at: index, in: characters) {
                    state = .normal
                    index += 3
                } else {
                    index += 1
                }
            case .multilineLiteral:
                if Self.hasTripleQuote("'", at: index, in: characters) {
                    state = .normal
                    index += 3
                } else {
                    index += 1
                }
            }
        }

        return switch state {
        case .multilineBasic: .basic
        case .multilineLiteral: .literal
        case .normal, .basic, .literal: nil
        }
    }

    private static func advanceNormalTOMLState(
        characters: [Character],
        state: inout TOMLScanState,
        index: inout Int)
    {
        let character = characters[index]
        if character == "#" {
            index = characters.count
        } else if character == "\"" {
            if Self.hasTripleQuote("\"", at: index, in: characters) {
                state = .multilineBasic
                index += 3
            } else {
                state = .basic
                index += 1
            }
        } else if character == "'" {
            if Self.hasTripleQuote("'", at: index, in: characters) {
                state = .multilineLiteral
                index += 3
            } else {
                state = .literal
                index += 1
            }
        } else {
            index += 1
        }
    }

    private static func hasTripleQuote(_ quote: Character, at index: Int, in characters: [Character]) -> Bool {
        index + 2 < characters.count &&
            characters[index] == quote &&
            characters[index + 1] == quote &&
            characters[index + 2] == quote
    }

    private static func tomlString(
        _ rawValue: String,
        followingLines: ArraySlice<String> = [])
        -> String?
    {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\"\"\"") || value.hasPrefix("'''") {
            let delimiter = value.hasPrefix("\"\"\"") ? "\"\"\"" : "'''"
            var fragments = [String(value.dropFirst(3))]
            fragments.append(contentsOf: followingLines)
            for index in fragments.indices {
                guard let end = fragments[index].range(of: delimiter) else { continue }
                fragments[index] = String(fragments[index][..<end.lowerBound])
                let startIndex = fragments.first?.isEmpty == true && index > 0 ? 1 : 0
                let content = fragments[startIndex...index].joined(separator: "\n")
                return delimiter == "'''" ? content : Self.decodeMultilineBasicString(content)
            }
            return nil
        }
        guard let quote = value.first, quote == "\"" || quote == "'" else { return nil }
        if quote == "'" {
            guard let end = value.dropFirst().firstIndex(of: "'") else { return nil }
            return String(value[value.index(after: value.startIndex)..<end])
        }

        var escaped = false
        var end: String.Index?
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            let character = value[index]
            if character == "\"", !escaped {
                end = index
                break
            }
            if character == "\\" {
                escaped.toggle()
            } else {
                escaped = false
            }
            index = value.index(after: index)
        }
        guard let end else { return nil }
        let token = String(value[...end])
        return try? JSONDecoder().decode(String.self, from: Data(token.utf8))
    }

    private static func decodeMultilineBasicString(_ value: String) -> String? {
        let scalars = Array(value.unicodeScalars)
        var result = ""
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\\" else {
                result.unicodeScalars.append(scalars[index])
                index += 1
                continue
            }

            index += 1
            guard index < scalars.count else { return nil }
            let escape = scalars[index]
            switch escape {
            case "b": result.append("\u{8}")
            case "t": result.append("\t")
            case "n": result.append("\n")
            case "f": result.append("\u{c}")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "u", "U":
                let digitCount = escape == "u" ? 4 : 8
                let start = index + 1
                let end = start + digitCount
                guard end <= scalars.count,
                      let codePoint = UInt32(String(String.UnicodeScalarView(scalars[start..<end])), radix: 16),
                      let scalar = UnicodeScalar(codePoint)
                else { return nil }
                result.unicodeScalars.append(scalar)
                index = end - 1
            case " ", "\t", "\n":
                var whitespaceIndex = index
                while whitespaceIndex < scalars.count,
                      scalars[whitespaceIndex] == " " || scalars[whitespaceIndex] == "\t"
                {
                    whitespaceIndex += 1
                }
                guard whitespaceIndex < scalars.count, scalars[whitespaceIndex] == "\n" else { return nil }
                index = whitespaceIndex
                while index + 1 < scalars.count,
                      scalars[index + 1].properties.isWhitespace
                {
                    index += 1
                }
            default: return nil
            }
            index += 1
        }
        return result
    }

    private struct SessionIndexEntry: Decodable {
        let id: String
        let threadName: String

        private enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
        }
    }

    private enum TOMLMultilineQuote {
        case basic
        case literal
    }

    private enum TOMLScanState {
        case normal
        case basic
        case literal
        case multilineBasic
        case multilineLiteral
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    private static func string(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column)
        else { return nil }
        let string = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }
    #endif
}
