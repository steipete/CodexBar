import Foundation
import Testing
@testable import CodexBarCore

enum Issue2037FixtureHarness {
    struct Fixture {
        let root: URL
        let manifest: Manifest
    }

    struct Manifest: Decodable, Equatable {
        struct File: Decodable, Equatable {
            let alias: String
            let relativePath: String
            let sourceRole: String
            let leafSessionAlias: String
            let parentSessionAlias: String?
        }

        struct CopiedPrefix: Decodable, Equatable {
            let parentAlias: String
            let childAlias: String
            let length: Int
        }

        struct Oracle: Decodable, Equatable {
            let parentEventCount: Int
            let childEventCount: Int
            let copiedPrefixLength: Int
            let parentLastTokens: Int
            let childLastTokens: Int
            let copiedPrefixLastTokens: Int
            let naiveLastTokens: Int
            let dedupedLastTokens: Int
            let copiedPrefixTimestampMismatches: Int
            let parentHasTotalTokenUsageDrop: Bool
            let childHasTotalTokenUsageDrop: Bool
        }

        struct ScannerOracle: Decodable, Equatable {
            let naiveScannerUnits: Int
            let dedupedScannerUnits: Int
            let prefixScannerUnits: Int
            let siblingAUniqueScannerUnits: Int?
            let siblingBUniqueScannerUnits: Int?
            let unresolvedForkSkippedFirstEventScannerUnits: Int?
        }

        let schemaVersion: Int
        let redactionVersion: Int
        let familyAlias: String
        let files: [File]
        let copiedPrefixes: [CopiedPrefix]
        let billablePrefixOwnerAlias: String?
        let missingParentSessionId: String?
        let oracle: Oracle?
        let scannerOracle: ScannerOracle?
    }

    static func load(named name: String) throws -> Fixture {
        let root = try #require(Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures/CostUsage/Issue2037"))
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        try self.validate(manifest)
        return Fixture(root: root, manifest: manifest)
    }

    static func install(_ fixture: Fixture, into environment: CostUsageTestEnvironment) throws {
        for file in fixture.manifest.files {
            let source = fixture.root.appendingPathComponent(file.relativePath, isDirectory: false)
            let destination = environment.root.appendingPathComponent(file.relativePath, isDirectory: false)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private static func validate(_ manifest: Manifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw FixtureError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.redactionVersion == 1 else {
            throw FixtureError.unsupportedRedaction(manifest.redactionVersion)
        }
        guard !manifest.familyAlias.isEmpty, !manifest.files.isEmpty else {
            throw FixtureError.emptyManifest
        }

        let aliases = Set(manifest.files.map(\.alias))
        guard aliases.count == manifest.files.count else {
            throw FixtureError.duplicateFileAlias
        }

        for file in manifest.files {
            guard !file.alias.isEmpty,
                  !file.leafSessionAlias.isEmpty,
                  file.relativePath.hasPrefix("codex-home/")
            else {
                throw FixtureError.invalidFileEntry(file.alias)
            }
            let components = file.relativePath.split(separator: "/")
            guard !components.contains(".."), !components.contains("") else {
                throw FixtureError.invalidFileEntry(file.alias)
            }
            if let parent = file.parentSessionAlias {
                guard !parent.isEmpty else {
                    throw FixtureError.invalidFileEntry(file.alias)
                }
            }
        }

        for prefix in manifest.copiedPrefixes {
            guard aliases.contains(prefix.parentAlias),
                  aliases.contains(prefix.childAlias),
                  prefix.parentAlias != prefix.childAlias,
                  prefix.length >= 0
            else {
                throw FixtureError.invalidCopiedPrefix
            }
        }
    }

    enum FixtureError: Error {
        case unsupportedSchema(Int)
        case unsupportedRedaction(Int)
        case emptyManifest
        case duplicateFileAlias
        case invalidFileEntry(String)
        case invalidCopiedPrefix
    }
}

enum SanitizedForkFamilyFixture {
    struct Fixture {
        let root: URL
        let manifest: Manifest

        func sessionMetadata(named alias: String) throws -> SessionMetadata {
            let file = try #require(self.manifest.files.first { $0.alias == alias })
            let url = self.root.appendingPathComponent(file.relativePath, isDirectory: false)
            let text = try String(contentsOf: url, encoding: .utf8)
            let record = try #require(text
                .split(whereSeparator: \.isNewline)
                .lazy
                .compactMap { line in
                    try? JSONDecoder().decode(Record.self, from: Data(line.utf8))
                }
                .first { $0.type == "session_meta" })
            let payload = try #require(record.payload)
            return try #require(payload.sessionMetadata)
        }

        func events(named alias: String) throws -> [TokenEvent] {
            let file = try #require(self.manifest.files.first { $0.alias == alias })
            let url = self.root.appendingPathComponent(file.relativePath, isDirectory: false)
            let text = try String(contentsOf: url, encoding: .utf8)
            return try text
                .split(whereSeparator: \.isNewline)
                .compactMap { line in
                    let record = try JSONDecoder().decode(Record.self, from: Data(line.utf8))
                    guard record.type == "event_msg",
                          record.payload?.type == "token_count",
                          let info = record.payload?.info,
                          let last = info.last,
                          let total = info.total
                    else {
                        return nil
                    }
                    return TokenEvent(timestamp: record.timestamp, last: last, total: total)
                }
        }

        func jsonObjects(named alias: String) throws -> [[String: Any]] {
            let file = try #require(self.manifest.files.first { $0.alias == alias })
            let url = self.root.appendingPathComponent(file.relativePath, isDirectory: false)
            let text = try String(contentsOf: url, encoding: .utf8)
            return try text
                .split(whereSeparator: \.isNewline)
                .map { line in
                    guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                    else {
                        throw FixtureError.invalidJSONLine
                    }
                    return object
                }
        }
    }

    struct Manifest: Decodable {
        struct File: Decodable {
            let alias: String
            let relativePath: String
        }

        struct CopiedPrefix: Decodable {
            let parentAlias: String
            let childAlias: String
            let length: Int
        }

        struct Oracle: Decodable {
            let parentEventCount: Int
            let childEventCount: Int
            let copiedPrefixLength: Int
            let parentLastTokens: Int
            let childLastTokens: Int
            let copiedPrefixLastTokens: Int
            let naiveLastTokens: Int
            let dedupedLastTokens: Int
            let copiedPrefixTimestampMismatches: Int
            let parentHasTotalTokenUsageDrop: Bool
            let childHasTotalTokenUsageDrop: Bool
        }

        let files: [File]
        let copiedPrefixes: [CopiedPrefix]
        let oracle: Oracle
    }

    struct TokenEvent: Equatable {
        struct Fingerprint: Equatable {
            let last: TokenUsage
            let total: TokenUsage
        }

        let timestamp: String
        let last: TokenUsage
        let total: TokenUsage

        var fingerprint: Fingerprint {
            .init(last: self.last, total: self.total)
        }
    }

    struct Record: Decodable {
        struct Payload: Decodable {
            struct SessionMetadata: Decodable {
                let id: String
                let forkedFromID: String?
                let timestamp: String

                enum CodingKeys: String, CodingKey {
                    case id
                    case forkedFromID = "forked_from_id"
                    case timestamp
                }
            }

            struct Info: Decodable {
                let last: TokenUsage?
                let total: TokenUsage?

                enum CodingKeys: String, CodingKey {
                    case last = "last_token_usage"
                    case total = "total_token_usage"
                }
            }

            let type: String?
            let info: Info?
            let sessionMetadata: SessionMetadata?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: DynamicCodingKey.self)
                self.type = try container.decodeIfPresent(String.self, forKey: .init("type"))
                self.info = try container.decodeIfPresent(Info.self, forKey: .init("info"))
                self.sessionMetadata = try? SessionMetadata(from: decoder)
            }
        }

        let type: String
        let timestamp: String
        let payload: Payload?
    }

    struct TokenUsage: Decodable, Equatable {
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let reasoningOutputTokens: Int
        private let recordedTotalTokens: Int?

        var totalTokens: Int {
            self.recordedTotalTokens ?? self.inputTokens + self.outputTokens
        }

        /// Scanner-priced token units (input + cached + output).
        var scannerUnits: Int {
            self.inputTokens + self.cachedInputTokens + self.outputTokens
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
            case totalTokens = "total_tokens"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.inputTokens = try max(0, container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0)
            self.cachedInputTokens = try max(
                0,
                container.decodeIfPresent(Int.self, forKey: .cachedInputTokens)
                    ?? container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens)
                    ?? 0)
            self.outputTokens = try max(0, container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0)
            self.reasoningOutputTokens = try max(
                0,
                container.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0)
            self.recordedTotalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens).map { max(0, $0) }
        }
    }

    typealias SessionMetadata = Record.Payload.SessionMetadata

    enum FixtureError: Error {
        case invalidJSONLine
        case unexpectedRecordType
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init(_ stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            nil
        }
    }

    static func load(named name: String) throws -> Fixture {
        let root = try #require(Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures/CostUsage/Issue2037"))
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        return try Fixture(
            root: root,
            manifest: JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)))
    }
}
