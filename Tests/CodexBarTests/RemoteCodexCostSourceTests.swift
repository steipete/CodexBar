import Foundation
import Testing
@testable import CodexBarCore

struct RemoteCodexCostSourceTests {
    @Test
    func `remote codex sources normalize and filter enabled ssh targets`() {
        let sources = [
            RemoteCodexCostSource(id: " remote host ", enabled: true, sshTarget: "user@example.com"),
            RemoteCodexCostSource(id: "disabled", enabled: false, sshTarget: "other@example.com"),
            RemoteCodexCostSource(id: "missing-target", enabled: true),
        ]

        let enabled = RemoteCodexCostSource.enabled(sources)

        #expect(enabled.count == 1)
        #expect(enabled.first?.sanitizedID == "remote-host")
        #expect(enabled.first?.sanitizedRemoteCodexHome == RemoteCodexCostSource.defaultRemoteCodexHome)
        #expect(enabled.first?.syncTimeoutSeconds == Int(RemoteCodexCostSource.defaultSyncTimeoutSeconds))
    }

    @Test
    func `remote codex source connection description includes port`() {
        let source = RemoteCodexCostSource(
            label: "Remote",
            sshTarget: "raykr@swroom.com",
            sshPort: 12140,
            remoteCodexHome: "~/.codex")

        #expect(source.connectionDescription == "raykr@swroom.com (port 12140): ~/.codex")
    }

    @Test
    func `remote codex file list filters by date paths`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let since = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 17)))
        let until = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 15)))
        let raw = """
        ./2026/05/16/rollout-2026-05-16T10-00-00-old.jsonl
        ./2026/05/17/rollout-2026-05-17T10-00-00-start.jsonl
        ./2026/06/15/rollout-2026-06-15T10-00-00-today.jsonl
        ./2026/06/16/rollout-2026-06-16T10-00-00-future.jsonl
        ./rollout-without-date.jsonl
        ./notes.txt
        """

        let filtered = RemoteCodexCostSyncer.filteredRelativeJSONLPaths(
            raw,
            window: RemoteCodexCostSyncWindow(since: since, until: until))

        #expect(filtered == [
            "2026/05/17/rollout-2026-05-17T10-00-00-start.jsonl",
            "2026/06/15/rollout-2026-06-15T10-00-00-today.jsonl",
            "rollout-without-date.jsonl",
        ])
    }

    @Test
    func `config round trips remote codex cost sources`() throws {
        let source = RemoteCodexCostSource(
            id: "gpu26",
            enabled: true,
            label: "GPU26",
            sshTarget: "gpu26",
            sshPort: 12139,
            remoteCodexHome: "/home/raykr/.codex",
            syncTimeoutSeconds: 90)
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: UsageProvider.codex, enabled: true, remoteCodexCostSources: [source]),
        ])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: data).normalized()
        let decodedSource = try #require(
            decoded.providerConfig(for: UsageProvider.codex)?.remoteCodexCostSources?.first)

        #expect(decodedSource == source)
    }
}
