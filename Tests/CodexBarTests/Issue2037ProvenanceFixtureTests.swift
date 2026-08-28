import Foundation
import Testing

struct Issue2037ProvenanceFixtureTests {
    @Test
    func `archived fork fixture preserves the copied normalized prefix and hand oracle`() throws {
        let fixture = try SanitizedForkFamilyFixture.load(named: "archived-fork-33ce-3869")
        let parentMetadata = try fixture.sessionMetadata(named: "parent")
        let childMetadata = try fixture.sessionMetadata(named: "child")
        let parent = try fixture.events(named: "parent")
        let child = try fixture.events(named: "child")
        let prefix = try #require(fixture.manifest.copiedPrefixes.first { prefix in
            prefix.parentAlias == "parent" && prefix.childAlias == "child"
        })

        let actualPrefixLength = Self.longestCommonNormalizedPrefix(parent, child)
        let copiedParent = Array(parent.prefix(prefix.length))
        let copiedChild = Array(child.prefix(prefix.length))
        let parentLastTokens = parent.map(\.last.totalTokens).reduce(0, +)
        let childLastTokens = child.map(\.last.totalTokens).reduce(0, +)
        let copiedLastTokens = copiedChild.map(\.last.totalTokens).reduce(0, +)
        let naiveLastTokens = parentLastTokens + childLastTokens
        let dedupedLastTokens = parentLastTokens + child.dropFirst(prefix.length)
            .map(\.last.totalTokens)
            .reduce(0, +)
        let timestampMismatches = zip(copiedParent, copiedChild)
            .count(where: { $0.timestamp != $1.timestamp })

        #expect(parent.count == fixture.manifest.oracle.parentEventCount)
        #expect(child.count == fixture.manifest.oracle.childEventCount)
        #expect(parentMetadata.id == "parent-session")
        #expect(parentMetadata.forkedFromID == nil)
        #expect(!parentMetadata.timestamp.isEmpty)
        #expect(childMetadata.id == "child-session")
        #expect(childMetadata.forkedFromID == "parent-session")
        #expect(!childMetadata.timestamp.isEmpty)
        #expect(actualPrefixLength == prefix.length)
        #expect(prefix.length == fixture.manifest.oracle.copiedPrefixLength)
        #expect(parent.prefix(prefix.length).map(\.fingerprint) == child.prefix(prefix.length).map(\.fingerprint))

        #expect(parentLastTokens == fixture.manifest.oracle.parentLastTokens)
        #expect(childLastTokens == fixture.manifest.oracle.childLastTokens)
        #expect(copiedLastTokens == fixture.manifest.oracle.copiedPrefixLastTokens)
        #expect(naiveLastTokens == fixture.manifest.oracle.naiveLastTokens)
        #expect(dedupedLastTokens == fixture.manifest.oracle.dedupedLastTokens)
        #expect(naiveLastTokens > dedupedLastTokens)
        #expect(timestampMismatches == fixture.manifest.oracle.copiedPrefixTimestampMismatches)
        #expect(timestampMismatches > 0)

        #expect(Self.hasTotalTokenUsageDrop(parent) == fixture.manifest.oracle.parentHasTotalTokenUsageDrop)
        #expect(Self.hasTotalTokenUsageDrop(child) == fixture.manifest.oracle.childHasTotalTokenUsageDrop)
    }

    @Test
    func `live fork 4d90 fixture preserves the copied normalized prefix and hand oracle`() throws {
        let fixture = try SanitizedForkFamilyFixture.load(named: "live-fork-4d90-52bf")
        let parentMetadata = try fixture.sessionMetadata(named: "parent")
        let childMetadata = try fixture.sessionMetadata(named: "child")
        let parent = try fixture.events(named: "parent")
        let child = try fixture.events(named: "child")
        let prefix = try #require(fixture.manifest.copiedPrefixes.first { prefix in
            prefix.parentAlias == "parent" && prefix.childAlias == "child"
        })

        let actualPrefixLength = Self.longestCommonNormalizedPrefix(parent, child)
        let copiedParent = Array(parent.prefix(prefix.length))
        let copiedChild = Array(child.prefix(prefix.length))
        let parentLastTokens = parent.map(\.last.totalTokens).reduce(0, +)
        let childLastTokens = child.map(\.last.totalTokens).reduce(0, +)
        let copiedLastTokens = copiedChild.map(\.last.totalTokens).reduce(0, +)
        let naiveLastTokens = parentLastTokens + childLastTokens
        let dedupedLastTokens = parentLastTokens + child.dropFirst(prefix.length)
            .map(\.last.totalTokens)
            .reduce(0, +)
        let timestampMismatches = zip(copiedParent, copiedChild)
            .count(where: { $0.timestamp != $1.timestamp })

        #expect(parent.count == fixture.manifest.oracle.parentEventCount)
        #expect(child.count == fixture.manifest.oracle.childEventCount)
        #expect(parentMetadata.id == "parent-session")
        #expect(parentMetadata.forkedFromID == nil)
        #expect(childMetadata.id == "child-session")
        #expect(childMetadata.forkedFromID == "parent-session")
        #expect(actualPrefixLength == prefix.length)
        #expect(prefix.length == fixture.manifest.oracle.copiedPrefixLength)
        #expect(parent.prefix(prefix.length).map(\.fingerprint) == child.prefix(prefix.length).map(\.fingerprint))

        #expect(parentLastTokens == fixture.manifest.oracle.parentLastTokens)
        #expect(childLastTokens == fixture.manifest.oracle.childLastTokens)
        #expect(copiedLastTokens == fixture.manifest.oracle.copiedPrefixLastTokens)
        #expect(naiveLastTokens == fixture.manifest.oracle.naiveLastTokens)
        #expect(dedupedLastTokens == fixture.manifest.oracle.dedupedLastTokens)
        #expect(naiveLastTokens > dedupedLastTokens)
        #expect(timestampMismatches == fixture.manifest.oracle.copiedPrefixTimestampMismatches)
        #expect(timestampMismatches > 0)
        #expect(Self.hasTotalTokenUsageDrop(parent) == false)
        #expect(Self.hasTotalTokenUsageDrop(child) == false)
    }

    @Test
    func `archived fork fixture admits only provenance safe fields`() throws {
        try Self.assertProvenanceSafeFields(named: "archived-fork-33ce-3869")
    }

    @Test
    func `live fork 4d90 fixture admits only provenance safe fields`() throws {
        try Self.assertProvenanceSafeFields(named: "live-fork-4d90-52bf")
    }

    private static func assertProvenanceSafeFields(named name: String) throws {
        let fixture = try SanitizedForkFamilyFixture.load(named: name)
        let usageKeys: Set = [
            "cached_input_tokens",
            "input_tokens",
            "output_tokens",
            "reasoning_output_tokens",
            "total_tokens",
        ]

        for alias in ["parent", "child"] {
            for record in try fixture.jsonObjects(named: alias) {
                #expect(Set(record.keys) == ["payload", "timestamp", "type"])
                let type = try #require(record["type"] as? String)
                let payload = try #require(record["payload"] as? [String: Any])

                switch type {
                case "session_meta":
                    #expect(Set(payload.keys) == ["forked_from_id", "id", "timestamp"])

                case "turn_context":
                    #expect(Set(payload.keys).isSubset(of: ["model", "multi_agent_mode", "multi_agent_version"]))
                    #expect(payload["model"] as? String == "fixture-model")

                case "event_msg":
                    #expect(Set(payload.keys) == ["info", "type"])
                    #expect(payload["type"] as? String == "token_count")
                    let info = try #require(payload["info"] as? [String: Any])
                    #expect(Set(info.keys) == ["last_token_usage", "total_token_usage"])
                    for usageName in ["last_token_usage", "total_token_usage"] {
                        let usage = try #require(info[usageName] as? [String: Any])
                        #expect(Set(usage.keys) == usageKeys)
                    }

                default:
                    throw SanitizedForkFamilyFixture.FixtureError.unexpectedRecordType
                }
            }
        }
    }

    private static func longestCommonNormalizedPrefix(
        _ parent: [SanitizedForkFamilyFixture.TokenEvent],
        _ child: [SanitizedForkFamilyFixture.TokenEvent]) -> Int
    {
        zip(parent, child).prefix { $0.fingerprint == $1.fingerprint }.count
    }

    private static func hasTotalTokenUsageDrop(_ events: [SanitizedForkFamilyFixture.TokenEvent]) -> Bool {
        zip(events, events.dropFirst()).contains { previous, next in
            next.total.totalTokens < previous.total.totalTokens
        }
    }
}
