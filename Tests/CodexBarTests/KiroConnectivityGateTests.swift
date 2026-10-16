import Foundation
import Testing
@testable import CodexBarCore

struct KiroConnectivityGateTests {
    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .cancelled])
    func `a failed connectivity check stops the CLI probe`(code: URLError.Code) async {
        let transport = ProviderHTTPTransportStub { _ in throw URLError(code) }
        let strategy = KiroCLIFetchStrategy(
            connectivityGate: Self.gate(transport: transport),
            makeProbe: {
                Issue.record("The CLI probe must not start after a failed connectivity check")
                return KiroStatusProbe(cliBinaryResolver: { nil })
            })

        await #expect(throws: URLError(code)) {
            try await strategy.fetch(Self.context())
        }
    }

    @Test(arguments: [200, 403, 503])
    func `an HTTP response lets the CLI probe run`(statusCode: Int) async throws {
        let transport = ProviderHTTPTransportStub { _ in (Data(), Self.kiroResponse(statusCode: statusCode)) }
        let strategy = KiroCLIFetchStrategy(
            connectivityGate: Self.gate(transport: transport),
            makeProbe: { KiroStatusProbe(cliBinaryResolver: { nil }) })

        await #expect {
            try await strategy.fetch(Self.context())
        } throws: { error in
            guard case KiroStatusProbeError.cliNotFound = error else { return false }
            return true
        }
        let request = try #require(await transport.requests().first)
        #expect(request.httpMethod == "HEAD")
        #expect(request.url == Self.usageURL)
        #expect(request.timeoutInterval == 4)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test
    func `unknown CLI state leaves refresh eligibility to the CLI`() async {
        let transport = ProviderHTTPTransportStub { _ in
            Issue.record("Unknown state must not contact a guessed endpoint")
            throw URLError(.notConnectedToInternet)
        }
        let gate = KiroConnectivityGate(transport: transport, resolveEndpoint: {
            throw KiroUsageLimitsError.credentialsUnavailable("synthetic missing profile")
        })
        let strategy = KiroCLIFetchStrategy(
            connectivityGate: gate,
            makeProbe: { KiroStatusProbe(cliBinaryResolver: { nil }) })

        await #expect {
            try await strategy.fetch(Self.context())
        } throws: { error in
            guard case KiroStatusProbeError.cliNotFound = error else { return false }
            return true
        }
        #expect(await transport.requests().isEmpty)
    }

    private static let usageURL = URL(string: "https://q.eu-central-1.amazonaws.com/")!

    @Test
    func `refresh recovers after an outage without contacting the dashboard`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("kiro-cli")
        let marker = directory.appendingPathComponent("started")
        let offline = directory.appendingPathComponent("offline")
        try Data().write(to: offline)
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
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url == Self.usageURL)
            if FileManager.default.fileExists(atPath: offline.path) {
                throw URLError(.notConnectedToInternet)
            }
            return (Data(), Self.kiroResponse(statusCode: 403))
        }
        let strategy = KiroCLIFetchStrategy(
            connectivityGate: Self.gate(transport: transport),
            makeProbe: { KiroStatusProbe(cliBinaryResolver: { cli.path }) })

        for _ in 0..<2 {
            await #expect(throws: URLError(.notConnectedToInternet)) {
                try await strategy.fetch(Self.context())
            }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: offline)
        let result = try await strategy.fetch(Self.context())
        #expect(result.usage.primary?.usedPercent == 25)
        #expect(result.usage.identity?.accountEmail == "person@example.com")
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    private static func gate(transport: any ProviderHTTPTransport) -> KiroConnectivityGate {
        KiroConnectivityGate(transport: transport, resolveEndpoint: { Self.usageURL })
    }

    private static func kiroResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: self.usageURL,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!
    }

    private static func context() -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
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
