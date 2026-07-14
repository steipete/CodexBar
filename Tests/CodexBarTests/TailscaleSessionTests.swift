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
    func `binary candidates prefer the CLI wrapper over the app binary`() throws {
        // A GUI-launched app inherits a minimal PATH that omits the CLI locations.
        let candidates = RemoteSessionFetcher.tailscaleBinaryCandidates(path: "/usr/bin:/bin")

        // The standard wrapper locations are still probed, ahead of the app binary…
        #expect(candidates.contains("/usr/local/bin/tailscale"))
        #expect(candidates.contains("/opt/homebrew/bin/tailscale"))
        // …and the dual-mode app binary is the last resort.
        #expect(candidates.last == "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        #expect(try #require(candidates.firstIndex(of: "/usr/local/bin/tailscale")) < candidates.count - 1)
    }

    @Test
    func `binary candidates keep PATH entries first and dedupe well-known dirs`() {
        let candidates = RemoteSessionFetcher.tailscaleBinaryCandidates(path: "/opt/homebrew/bin:/usr/bin")

        #expect(candidates.first == "/opt/homebrew/bin/tailscale")
        #expect(candidates.count(where: { $0 == "/opt/homebrew/bin/tailscale" }) == 1)
    }

    @Test
    func `cli environment injects a shell marker for the app-binary fallback`() {
        // Without a marker the dual-mode binary launches the GUI instead of the CLI.
        let env = RemoteSessionFetcher.tailscaleCLIEnvironment(from: ["PATH": "/usr/bin"])

        #expect(env["SHLVL"] == "1")
    }

    @Test
    func `cli environment preserves an existing terminal context`() {
        // Already CLI-safe: leave TERM alone and don't fabricate a SHLVL…
        let withTerm = RemoteSessionFetcher.tailscaleCLIEnvironment(from: ["TERM": "xterm-256color"])
        #expect(withTerm["SHLVL"] == nil)

        // …and never clobber a caller-provided SHLVL.
        let withShlvl = RemoteSessionFetcher.tailscaleCLIEnvironment(from: ["SHLVL": "3"])
        #expect(withShlvl["SHLVL"] == "3")
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
            localHost: "local-mac")
        { binary in
            probed.append(binary)
            return binary == "/first/tailscale" ? Data(#"{"Version":"1.0"}"#.utf8) : validStatus
        }

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
            localHost: "local-mac")
        { binary in
            probed.append(binary)
            return binary == "/inactive/tailscale" ? inactiveStatus : runningStatus
        }

        #expect(hosts == ["linuxbox"])
        #expect(probed == ["/inactive/tailscale", "/running/tailscale"])
    }

    @Test
    func `discovery returns empty when no candidate yields a valid status`() async {
        let hosts = await RemoteSessionFetcher.firstDiscoveredHosts(
            candidates: ["/a/tailscale", "/b/tailscale"],
            localHost: nil) { _ in Data("nope".utf8) }

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
            "-oProxyCommand=touch /tmp/unsafe",
            "host with-space",
            "host\nother",
            "linuxbox",
        ])

        #expect(hosts == ["user@clawmac", "linuxbox"])
    }
}
