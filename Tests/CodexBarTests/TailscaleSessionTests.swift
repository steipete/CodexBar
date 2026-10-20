import CodexBarCore
import Foundation
import Testing

struct TailscaleSessionTests {
    @Test
    func `online mac and linux peers become hosts`() throws {
        let url = try AgentSessionParserTests.fixtureURL("agent-sessions-tailscale", extension: "json")
        let hosts = try TailscaleStatusParser.hosts(
            from: Data(contentsOf: url),
            excludingLocalHost: "local-mac")

        #expect(hosts == ["clawmac", "linuxbox"])
    }

    @Test
    func `binary candidates never include the app bundle`() {
        let candidates = RemoteSessionFetcher.tailscaleBinaryCandidates(path: "/usr/bin:/bin")
        #expect(candidates.contains("/usr/local/bin/tailscale"))
        #expect(candidates.contains("/opt/homebrew/bin/tailscale"))
        #expect(!candidates.contains("/Applications/Tailscale.app/Contents/MacOS/Tailscale"))
    }

    @Test
    func `discovery skips app binaries symlinks and launch wrappers`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Tailscale.app/Contents/MacOS/Tailscale")
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cli = root.appendingPathComponent("tailscale")
        let link = root.appendingPathComponent("linked-tailscale")
        let wrapper = root.appendingPathComponent("wrapped-tailscale")
        for file in [app, cli] {
            try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        try Data("#!/bin/sh\nexec /Applications/Tailscale.app/Contents/MacOS/Tailscale \"$@\"\n".utf8)
            .write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        var probed: [String] = []
        _ = await RemoteSessionFetcher.firstDiscoveredHosts(
            candidates: [app.path, link.path, wrapper.path, cli.path], localHost: nil)
        { binary in
            probed.append(binary)
            return nil
        }
        #expect(probed == [cli.path])
    }

    @Test
    func `binary candidates keep PATH entries first and dedupe well-known dirs`() {
        let candidates = RemoteSessionFetcher.tailscaleBinaryCandidates(path: "/opt/homebrew/bin:/usr/bin")

        #expect(candidates.first == "/opt/homebrew/bin/tailscale")
        #expect(candidates.count(where: { $0 == "/opt/homebrew/bin/tailscale" }) == 1)
    }

    @Test
    func `discovery falls through to the next candidate when the first fails`() async {
        // First candidate exists but is a wrong/broken tailscale variant: its status output isn't valid
        // Tailscale JSON. Discovery must try the next candidate rather than returning no hosts.
        let validStatus = Data(#"""
        {"Version":"1.0","Self":{"HostName":"local-mac"},
         "Peer":{"n":{"Online":true,"OS":"linux","DNSName":"linuxbox.tail.ts.net."}}}
        """#.utf8)
        var probed: [String] = []
        let hosts = await RemoteSessionFetcher.firstDiscoveredHosts(
            candidates: ["/first/tailscale", "/second/tailscale"],
            localHost: "local-mac",
            isStandaloneCLI: { _ in true },
            run: { binary in
                probed.append(binary)
                return binary == "/first/tailscale" ? Data(#"{"Version":"1.0"}"#.utf8) : validStatus
            })

        #expect(hosts == ["linuxbox"])
        #expect(probed == ["/first/tailscale", "/second/tailscale"]) // fell through, in order
    }

    @Test
    func `discovery falls through when an earlier candidate needs login`() async {
        let inactiveStatus = Data(#"{"Version":"1.0","BackendState":"NeedsLogin","Peer":null}"#.utf8)
        let runningStatus = Data(#"""
        {"Version":"1.0","BackendState":"Running","Self":{"HostName":"local-mac"},
         "Peer":{"n":{"Online":true,"OS":"linux","DNSName":"linuxbox.tail.ts.net."}}}
        """#.utf8)
        var probed: [String] = []
        let hosts = await RemoteSessionFetcher.firstDiscoveredHosts(
            candidates: ["/inactive/tailscale", "/running/tailscale"],
            localHost: "local-mac",
            isStandaloneCLI: { _ in true },
            run: { binary in
                probed.append(binary)
                return binary == "/inactive/tailscale" ? inactiveStatus : runningStatus
            })

        #expect(hosts == ["linuxbox"])
        #expect(probed == ["/inactive/tailscale", "/running/tailscale"])
    }

    @Test
    func `discovery returns empty when no candidate yields a valid status`() async {
        let hosts = await RemoteSessionFetcher.firstDiscoveredHosts(
            candidates: ["/a/tailscale", "/b/tailscale"],
            localHost: nil,
            isStandaloneCLI: { _ in true },
            run: { _ in Data("nope".utf8) })

        #expect(hosts.isEmpty)
    }

    @Test
    func `parseHosts distinguishes invalid output from an empty tailnet`() {
        // Non-status output -> nil so the caller falls through to the next candidate…
        #expect(TailscaleStatusParser.parseHosts(from: Data("not json".utf8)) == nil)
        #expect(TailscaleStatusParser.parseHosts(from: Data("Tailscale help text".utf8)) == nil)
        #expect(TailscaleStatusParser.parseHosts(from: Data(#"{"Version":"1.0"}"#.utf8)) == nil)
        #expect(TailscaleStatusParser.parseHosts(from: Data(#"{"Self":null}"#.utf8)) == nil)
        #expect(TailscaleStatusParser.parseHosts(from: Data(#"{"Peer":"error"}"#.utf8)) == nil)
        // …a valid status with no eligible peers -> [] (a real answer, stop probing).
        let empty = TailscaleStatusParser.parseHosts(
            from: Data(#"{"Version":"1.0","BackendState":"Running","Self":{},"Peer":null}"#.utf8))
        #expect(empty == [])
        #expect(TailscaleStatusParser.parseHosts(
            from: Data(#"{"Version":"1.0","BackendState":"NeedsLogin","Peer":null}"#.utf8)) == nil)
    }

    @Test
    func `ssh destinations reject options whitespace and controls`() {
        let hosts = RemoteSessionFetcher.sanitizedHosts([
            "user@clawmac",
            "USER@CLAWMAC",
            "user@CLAWMAC",
            "-oProxyCommand=touch /tmp/unsafe",
            "host with-space",
            "host\nother",
            "linuxbox",
        ])

        #expect(hosts == ["user@clawmac", "USER@CLAWMAC", "linuxbox"])
    }

    @Test
    func `remote session command negotiates v2 then v1 for PATH and bundled CLIs`() {
        #expect(RemoteSessionFetcher.remoteSessionsCommand() ==
            "codexbar sessions --json-v2 || codexbar sessions --json || " +
            "'/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI' sessions --json-v2 || " +
            "'/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI' sessions --json")
    }
}
