import CodexBarCore
import Foundation
import Testing

struct CodexSessionRolloutTests {
    @Test
    func `first rollout line maps to file only agent session`() throws {
        let url = try AgentSessionParserTests.fixtureURL("agent-session-rollout", extension: "jsonl")
        let metadata = try #require(CodexRolloutFirstLineParser.read(from: url))
        let now = Date(timeIntervalSince1970: 10000)
        let modifiedAt = now.addingTimeInterval(-60)
        let session = try #require(CodexRolloutFirstLineParser.makeSession(
            metadata: metadata,
            transcriptURL: url,
            modifiedAt: modifiedAt,
            host: "local-mac",
            now: now))

        #expect(session.id == "019f-session-fixture")
        #expect(session.cwd == "/Users/test/Projects/alpha")
        #expect(session.projectName == "alpha")
        #expect(session.source == .cli)
        #expect(session.state == .active)
        #expect(session.pid == nil)
    }

    @Test
    func `file only rollout outside window is excluded while live process remains`() throws {
        let url = try AgentSessionParserTests.fixtureURL("agent-session-rollout", extension: "jsonl")
        let metadata = try #require(CodexRolloutFirstLineParser.read(from: url))
        let now = Date(timeIntervalSince1970: 10000)
        let modifiedAt = now.addingTimeInterval(-1801)

        #expect(CodexRolloutFirstLineParser.makeSession(
            metadata: metadata,
            transcriptURL: url,
            modifiedAt: modifiedAt,
            host: "local-mac",
            now: now) == nil)
        #expect(CodexRolloutFirstLineParser.makeSession(
            metadata: metadata,
            transcriptURL: url,
            modifiedAt: modifiedAt,
            pid: 42,
            host: "local-mac",
            now: now)?.state == .idle)
    }

    @Test
    func `app server presence classifies unknown file only rollout as desktop`() {
        #expect(AgentSessionCorrelation.fileOnlyCodexSource(
            metadataSource: .unknown,
            appServerPresent: true) == .desktopApp)
        #expect(AgentSessionCorrelation.fileOnlyCodexSource(
            metadataSource: .unknown,
            appServerPresent: false) == .unknown)
    }

    @Test
    func `codex cwd matching rejects missing paths`() {
        #expect(AgentSessionCorrelation.codexWorkingDirectoriesMatch("/repo/alpha", "/repo/./alpha"))
        #expect(!AgentSessionCorrelation.codexWorkingDirectoriesMatch(nil, nil))
        #expect(!AgentSessionCorrelation.codexWorkingDirectoriesMatch("/repo/alpha", nil))
    }
}
