import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct KiroBackgroundConnectivityTests {
    @Test
    func `offline background refresh never starts the CLI and keeps last good usage`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("kiro-cli")
        let marker = directory.appendingPathComponent("started")
        let script = """
        #!/bin/sh
        : > '\(marker.path)'
        if [ "$1" = "whoami" ]; then
          printf 'Logged in with Google\\nEmail: person@example.com\\n'
        elif [ "$3" = "/usage" ]; then
          printf 'Estimated Usage | resets on 2027-06-01 | KIRO FREE\\n'
          printf 'Credits (12.50 of 50 covered in plan)\\n'
          printf '████████████████████ 25%%\\n'
        fi
        """
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let offline = LockIsolated(true)
        let transport = ProviderHTTPTransportStub { request in
            if offline.value { throw URLError(.notConnectedToInternet) }
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 403, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }
        let strategy = KiroCLIFetchStrategy(
            checkConnectivity: {
                _ = try await transport.data(for: URLRequest(url: Self.defaultUsageURL))
            },
            makeProbe: { KiroStatusProbe(cliBinaryResolver: { cli.path }) })

        try await ProviderInteractionContext.$current.withValue(.background) {
            for _ in 0..<2 {
                do {
                    _ = try await strategy.fetch(Self.context())
                    Issue.record("Offline background refresh unexpectedly launched the CLI")
                } catch {
                    #expect((error as? URLError)?.code == .notConnectedToInternet)
                    #expect(UsageStore.shouldPreservePriorSnapshot(after: error, hadPriorData: true))
                }
            }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            offline.setValue(false)
            let result = try await strategy.fetch(Self.context())
            #expect(result.usage.primary?.usedPercent == 25)
            #expect(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test
    func `missing private state still gates the CLI on the default usage host`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = directory.appendingPathComponent("data.sqlite3")
        let transport = ProviderHTTPTransportStub { _ in throw URLError(.notConnectedToInternet) }
        let strategy = KiroCLIFetchStrategy(
            checkConnectivity: {
                try await KiroUsageLimitsAPI.ensureReachable(databaseURL: database, transport: transport)
            },
            makeProbe: {
                Issue.record("Missing private state must not permit an offline CLI launch")
                return KiroStatusProbe(cliBinaryResolver: { nil })
            })

        await #expect(throws: URLError(.notConnectedToInternet)) {
            try await ProviderInteractionContext.$current.withValue(.background) {
                try await strategy.fetch(Self.context())
            }
        }
        let requests = await transport.requests()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.url == Self.defaultUsageURL)
        #expect(request.httpMethod == "HEAD")
        #expect(request.timeoutInterval == 4)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test
    func `manual refresh keeps its existing CLI path`() async {
        let strategy = KiroCLIFetchStrategy(
            checkConnectivity: { Issue.record("Manual refresh must not use the background preflight") },
            makeProbe: { KiroStatusProbe(cliBinaryResolver: { nil }) })
        await #expect {
            try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                try await strategy.fetch(Self.context())
            }
        } throws: { error in
            guard case KiroStatusProbeError.cliNotFound = error else { return false }
            return true
        }
    }

    private static let defaultUsageURL = URL(string: "https://codewhisperer.us-east-1.amazonaws.com/")!

    private static func context() -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}
