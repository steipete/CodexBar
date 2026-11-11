import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import Security

struct KeychainAccessPreflightPartitionTests {
    private static func description(_ partitions: [String]) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Partitions": partitions],
            format: .xml,
            options: 0)
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// Builds an in-memory access object (no Keychain item is created) carrying the given extra ACLs.
    /// Deprecated SecKeychain ACL APIs are the only way to shape one; the annotation keeps the build quiet.
    @available(macOS, deprecated: 10.10)
    private static func access(acls: [(authorization: CFString, description: String)]) throws -> SecAccess {
        var access: SecAccess?
        #expect(SecAccessCreate("partition-test" as CFString, [] as CFArray, &access) == errSecSuccess)
        let created = try #require(access)
        for entry in acls {
            var acl: SecACL?
            #expect(SecACLCreateWithSimpleContents(
                created,
                nil,
                entry.description as CFString,
                SecKeychainPromptSelector(),
                &acl) == errSecSuccess)
            #expect(try SecACLUpdateAuthorizations(#require(acl), [entry.authorization] as CFArray) == errSecSuccess)
        }
        return created
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `native partition entry decides the outcome for the caller's team`() throws {
        let access = try Self.access(acls: [
            (kSecACLAuthorizationPartitionID, Self.description(["teamid:V9WTTPBFK9"])),
        ])
        #expect(KeychainAccessPreflight.evaluatePartitionList(access: access, callerTeam: "Y5PE65HELJ") == .rejected)
        #expect(KeychainAccessPreflight.evaluatePartitionList(access: access, callerTeam: "V9WTTPBFK9") == .allowed)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `an any-operation ACL is not read as a partition list`() throws {
        // Matching by authorization also returns wildcard ACLs; their plain descriptions must not
        // turn a readable item into an inconclusive one.
        let wildcardOnly = try Self.access(acls: [(kSecACLAuthorizationAny, "not a partition payload")])
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: wildcardOnly,
            callerTeam: "Y5PE65HELJ") == .allowed)

        let wildcardAndPartition = try Self.access(acls: [
            (kSecACLAuthorizationAny, "not a partition payload"),
            (kSecACLAuthorizationPartitionID, Self.description(["teamid:Y5PE65HELJ"])),
        ])
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: wildcardAndPartition,
            callerTeam: "Y5PE65HELJ") == .allowed)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `an unreadable explicit partition entry is inconclusive`() throws {
        let access = try Self.access(acls: [(kSecACLAuthorizationPartitionID, "not hex")])
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: access,
            callerTeam: "Y5PE65HELJ") == .indeterminate)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `an item without a partition entry keeps the decrypt ACL answer`() throws {
        // SecAccessCopyMatchingACLList answers NULL for this access, the same value it uses for a failure;
        // the full ACL list must still prove that no partition entry exists.
        let access = try Self.access(acls: [])
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: access,
            callerTeam: "Y5PE65HELJ") == .allowed)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `a failed ACL list lookup is inconclusive, not an item without partitions`() throws {
        let access = try Self.access(acls: [])
        var operations = try #require(KeychainAccessPreflight.PartitionACLOperations.live)
        operations.copyACLList = { _ in nil }
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: access,
            callerTeam: "Y5PE65HELJ",
            operations: operations) == .indeterminate)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `a failed authorization lookup cannot hide a partition entry`() throws {
        // The rejecting partition entry would decide the outcome if its authorizations were readable.
        let access = try Self.access(acls: [
            (kSecACLAuthorizationPartitionID, Self.description(["teamid:V9WTTPBFK9"])),
        ])
        let live = try #require(KeychainAccessPreflight.PartitionACLOperations.live)
        var operations = live
        operations.copyAuthorizations = { acl in
            let authorizations = live.copyAuthorizations(acl)
            return authorizations?.contains(kSecACLAuthorizationPartitionID as String) == true ? nil : authorizations
        }
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: access,
            callerTeam: "Y5PE65HELJ",
            operations: operations) == .indeterminate)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `a failed partition description lookup is inconclusive`() throws {
        let access = try Self.access(acls: [
            (kSecACLAuthorizationPartitionID, Self.description(["teamid:Y5PE65HELJ"])),
        ])
        var operations = try #require(KeychainAccessPreflight.PartitionACLOperations.live)
        operations.copyDescription = { _ in nil }
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: access,
            callerTeam: "Y5PE65HELJ",
            operations: operations) == .indeterminate)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `missing Security functions are inconclusive`() throws {
        let access = try Self.access(acls: [])
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: access,
            callerTeam: "Y5PE65HELJ",
            operations: nil) == .indeterminate)
    }

    @Test
    func `partition description decodes the hex property list Security returns`() throws {
        let ids = ["teamid:V9WTTPBFK9", "apple-tool:"]
        #expect(try KeychainAccessPreflight.partitionIDs(fromACLDescription: Self.description(ids)) == ids)
    }

    @Test
    func `malformed partition descriptions are unreadable, not empty`() {
        for description in ["", "abc", "zz", "ai.meta.dev.credentials", "deadbeef"] {
            #expect(KeychainAccessPreflight.partitionIDs(fromACLDescription: description) == nil)
        }
    }

    @Test
    func `caller team on the partition list is allowed`() {
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            ["apple-tool:", "teamid:Y5PE65HELJ"],
            callerTeam: "Y5PE65HELJ") == .allowed)
    }

    @Test
    func `another vendor's partition list is rejected even when the decrypt ACL names the caller`() {
        // Observed on a Muse CLI item: CodexBarCLI on the decrypt ACL, only Meta's team partitioned.
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            ["teamid:V9WTTPBFK9"],
            callerTeam: "Y5PE65HELJ") == .rejected)
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            ["apple:", "apple-tool:"],
            callerTeam: "Y5PE65HELJ") == .rejected)
        #expect(KeychainAccessPreflight.evaluatePartitionList([], callerTeam: "Y5PE65HELJ") == .rejected)
    }

    @Test
    func `a team id must match the whole partition entry`() {
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            ["teamid:Y5PE65HELJX", "Y5PE65HELJ"],
            callerTeam: "Y5PE65HELJ") == .rejected)
    }

    @Test
    func `a build without a team keeps the decrypt ACL answer`() {
        #expect(KeychainAccessPreflight.evaluatePartitionList(["teamid:V9WTTPBFK9"], callerTeam: .noTeam) == .allowed)
    }

    @Test
    func `an unreadable caller identity is inconclusive, never a build without a team`() {
        for partitions in [["teamid:V9WTTPBFK9"], ["teamid:Y5PE65HELJ"]] {
            #expect(KeychainAccessPreflight.evaluatePartitionList(partitions, callerTeam: .unknown) == .indeterminate)
        }
        #expect(KeychainAccessPreflight.evaluatePartitionList(["teamid:"], callerTeam: .team("")) == .indeterminate)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `an unreadable caller identity never allows an item that excludes it`() throws {
        // A signed build whose identity read failed must not pass as a teamless build: the item below would
        // prompt for it.
        let access = try Self.access(acls: [
            (kSecACLAuthorizationPartitionID, Self.description(["teamid:V9WTTPBFK9"])),
        ])
        #expect(KeychainAccessPreflight.evaluatePartitionList(access: access, callerTeam: .unknown) == .indeterminate)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `an unreadable caller identity still reads an item without a partition entry`() throws {
        // Such an item does not depend on the caller's team, so the unknown identity must not block it.
        let access = try Self.access(acls: [(kSecACLAuthorizationAny, "not a partition payload")])
        #expect(KeychainAccessPreflight.evaluatePartitionList(access: access, callerTeam: .unknown) == .allowed)
    }

    @Test
    func `only a determinate caller identity is cached`() {
        let cache = KeychainAccessPreflight.CallerTeamCache()
        var reads = 0
        var answers: [KeychainAccessPreflight.CallerTeam] = [.unknown, .team("Y5PE65HELJ"), .noTeam]
        let read = {
            reads += 1
            return answers.removeFirst()
        }
        #expect(cache.value(read: read) == .unknown)
        #expect(cache.value(read: read) == .team("Y5PE65HELJ"))
        #expect(cache.value(read: read) == .team("Y5PE65HELJ"))
        #expect(reads == 2)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `a caller without a team id never runs the partition lookups`() throws {
        // Ad-hoc and unsigned builds must keep the decrypt ACL answer even when the lookups would fail.
        let access = try Self.access(acls: [])
        let failing = KeychainAccessPreflight.PartitionACLOperations(
            copyACLList: { _ in nil },
            copyAuthorizations: { _ in nil },
            copyDescription: { _ in nil })
        for team in [.noTeam] as [KeychainAccessPreflight.CallerTeam] {
            for operations in [failing, nil] as [KeychainAccessPreflight.PartitionACLOperations?] {
                #expect(KeychainAccessPreflight.evaluatePartitionList(
                    access: access,
                    callerTeam: team,
                    operations: operations) == .allowed)
            }
        }
    }

    @Test
    func `the operation memo never answers a partition check with a decrypt-only result`() {
        var calls: [Bool] = []
        let outcomes = KeychainAccessPreflight.withPartitionAwareCheckGenericPasswordOverrideForTesting
            { _, _, requireCallerPartition in
                calls.append(requireCallerPartition)
                return requireCallerPartition ? .interactionRequired : .allowed
            } operation: {
                KeychainAccessPreflight.withMemoizedGenericPasswordChecks {
                    [
                        KeychainAccessPreflight.checkGenericPassword(
                            service: "partition-memo",
                            account: nil,
                            requireCallerPartition: false),
                        KeychainAccessPreflight.checkGenericPassword(service: "partition-memo", account: nil),
                        KeychainAccessPreflight.checkGenericPassword(service: "partition-memo", account: nil),
                    ]
                }
            }
        #expect(outcomes == [.allowed, .interactionRequired, .interactionRequired])
        #expect(calls == [false, true])
    }
}
#endif
