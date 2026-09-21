import CryptoKit
import Foundation
@testable import CodexBarCore

struct PiNativeProofCorpus: Sendable {
    let output: URL
    var root: URL {
        self.output.appendingPathComponent("corpus", isDirectory: true)
    }

    var cache: URL {
        self.output.appendingPathComponent("cache", isDirectory: true)
    }

    var claude: URL {
        self.root.appendingPathComponent("claude-projects", isDirectory: true)
    }

    var pi: URL {
        self.root.appendingPathComponent("pi-sessions", isDirectory: true)
    }

    var parkedPi: URL {
        self.root.appendingPathComponent("pi-offline", isDirectory: true)
    }

    var omp: URL {
        self.root.appendingPathComponent("empty-omp", isDirectory: true)
    }

    var widgetURL: URL {
        self.output.appendingPathComponent("widget-snapshot.json")
    }

    var piFile: URL {
        self.pi.appendingPathComponent("native-proof.jsonl")
    }

    var isOffline: Bool {
        FileManager.default.fileExists(atPath: self.parkedPi.path)
    }

    var hasAppended: Bool {
        let file = self.isOffline ? self.parkedPi.appendingPathComponent("native-proof.jsonl") : self.piFile
        return (try? String(contentsOf: file, encoding: .utf8))?.contains("\"id\":\"pi-appended\"") == true
    }

    var environment: [String: String] {
        [
            "HOME": self.root.path,
            "PI_CODING_AGENT_SESSION_DIR": self.pi.path,
            "PI_CONFIG_DIR": "omp-config",
        ]
    }

    var scannerOptions: CostUsageScanner.Options {
        .init(
            codexSessionsRoot: self.root.appendingPathComponent("empty-codex"),
            claudeProjectsRoots: [self.claude],
            cacheRoot: self.cache,
            calendar: .current)
    }

    var piOptions: PiSessionCostScanner.Options {
        .init(
            piSessionsRoot: self.pi,
            ompSessionsRoot: self.omp,
            cacheRoot: self.cache,
            calendar: .current,
            refreshMinIntervalSeconds: 0,
            environment: self.environment,
            workingDirectory: self.root,
            processContexts: [])
    }

    func prepare() throws {
        let manager = FileManager.default
        for directory in [self.output, self.root, self.cache, self.claude, self.omp] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let marker = self.output.appendingPathComponent("corpus-created.json")
        guard !manager.fileExists(atPath: marker.path) else { return }
        let native = self.claude.appendingPathComponent("native.jsonl")
        guard !manager.fileExists(atPath: native.path), !manager.fileExists(atPath: self.piFile.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try manager.createDirectory(at: self.pi, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let row: [String: Any] = [
            "type": "assistant", "timestamp": stamp, "sessionId": "native-proof", "requestId": "native-1",
            "message": [
                "id": "native-message-1",
                "model": "claude-sonnet-4-6",
                "stop_reason": "end_turn",
                "usage": [
                    "input_tokens": 200_000,
                    "output_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "cache_creation_input_tokens": 0,
                ],
            ],
        ]
        try Self.jsonLine(row).write(to: native, options: .atomic)
        let header: [String: Any] = [
            "type": "session", "version": 3, "id": "pi-proof-session", "timestamp": stamp, "cwd": root.path,
        ]
        var piData = try Self.jsonLine(header)
        try piData.append(Self.jsonLine(Self.piRow(id: "pi-initial", input: 40000, timestamp: stamp)))
        try piData.write(to: self.piFile, options: .atomic)
        try Self.jsonLine(["createdAt": stamp, "syntheticOnly": true]).write(to: marker, options: .atomic)
    }

    func makeOffline() throws {
        guard !self.isOffline else { return }
        try FileManager.default.moveItem(at: self.pi, to: self.parkedPi)
    }

    func restoreAndAppend() throws {
        if self.isOffline {
            try FileManager.default.moveItem(at: self.parkedPi, to: self.pi)
        }
        guard !self.hasAppended else { return }
        let row = Self.piRow(
            id: "pi-appended", input: 10000, timestamp: ISO8601DateFormatter().string(from: Date()))
        let handle = try FileHandle(forWritingTo: piFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Self.jsonLine(row))
    }

    func load(
        provider: UsageProvider,
        force: Bool,
        now: Date,
        historyDays: Int,
        includePi: Bool) async throws -> CostUsageTokenResult
    {
        try await CostUsageFetcher.loadTokenResult(
            provider: provider,
            environment: self.environment,
            now: now,
            forceRefresh: force,
            historyDays: historyDays,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: includePi,
            bypassScannerDebounce: true,
            piSessionProcessContexts: [],
            scannerOptions: self.scannerOptions,
            piScannerOptions: self.piOptions)
    }

    func cacheEvidence() -> [String: Any] {
        let url = PiSessionCostCacheIO.cacheFileURL(cacheRoot: self.cache)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return [
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "lastScanUnixMs": object?["lastScanUnixMs"] ?? NSNull(),
        ]
    }

    private static func piRow(id: String, input: Int, timestamp: String) -> [String: Any] {
        [
            "type": "message",
            "id": id,
            "timestamp": timestamp,
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": "claude-sonnet-4-6",
                "usage": [
                    "input": input,
                    "output": 0,
                    "cacheRead": 0,
                    "cacheWrite": 0,
                    "totalTokens": input,
                ],
            ],
        ]
    }

    private static func jsonLine(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}
