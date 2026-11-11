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
        #expect(KeychainAccessPreflight.evaluatePartitionList(access: access, callerTeamID: "Y5PE65HELJ") == .rejected)
        #expect(KeychainAccessPreflight.evaluatePartitionList(access: access, callerTeamID: "V9WTTPBFK9") == .allowed)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `an any-operation ACL is not read as a partition list`() throws {
        // Matching by authorization also returns wildcard ACLs; their plain descriptions must not
        // turn a readable item into an inconclusive one.
        let wildcardOnly = try Self.access(acls: [(kSecACLAuthorizationAny, "not a partition payload")])
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: wildcardOnly,
            callerTeamID: "Y5PE65HELJ") == .allowed)

        let wildcardAndPartition = try Self.access(acls: [
            (kSecACLAuthorizationAny, "not a partition payload"),
            (kSecACLAuthorizationPartitionID, Self.description(["teamid:Y5PE65HELJ"])),
        ])
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: wildcardAndPartition,
            callerTeamID: "Y5PE65HELJ") == .allowed)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `an unreadable explicit partition entry is inconclusive`() throws {
        let access = try Self.access(acls: [(kSecACLAuthorizationPartitionID, "not hex")])
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: access,
            callerTeamID: "Y5PE65HELJ") == .indeterminate)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `an item without a partition entry keeps the decrypt ACL answer`() throws {
        // SecAccessCopyMatchingACLList answers NULL for this access, the same value it uses for a failure;
        // the full ACL list must still prove that no partition entry exists.
        let access = try Self.access(acls: [])
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: access,
            callerTeamID: "Y5PE65HELJ") == .allowed)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `a failed ACL list lookup is inconclusive, not an item without partitions`() throws {
        let access = try Self.access(acls: [])
        var operations = try #require(KeychainAccessPreflight.PartitionACLOperations.live)
        operations.copyACLList = { _ in nil }
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: access,
            callerTeamID: "Y5PE65HELJ",
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
            callerTeamID: "Y5PE65HELJ",
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
            callerTeamID: "Y5PE65HELJ",
            operations: operations) == .indeterminate)
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `missing Security functions are inconclusive`() throws {
        let access = try Self.access(acls: [])
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            access: access,
            callerTeamID: "Y5PE65HELJ",
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
            callerTeamID: "Y5PE65HELJ") == .allowed)
    }

    @Test
    func `another vendor's partition list is rejected even when the decrypt ACL names the caller`() {
        // Observed on a Muse CLI item: CodexBarCLI on the decrypt ACL, only Meta's team partitioned.
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            ["teamid:V9WTTPBFK9"],
            callerTeamID: "Y5PE65HELJ") == .rejected)
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            ["apple:", "apple-tool:"],
            callerTeamID: "Y5PE65HELJ") == .rejected)
        #expect(KeychainAccessPreflight.evaluatePartitionList([], callerTeamID: "Y5PE65HELJ") == .rejected)
    }

    @Test
    func `a team id must match the whole partition entry`() {
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            ["teamid:Y5PE65HELJX", "Y5PE65HELJ"],
            callerTeamID: "Y5PE65HELJ") == .rejected)
    }

    @Test
    func `a caller without a team id keeps the decrypt ACL answer`() {
        for team in [nil, ""] as [String?] {
            #expect(KeychainAccessPreflight.evaluatePartitionList(
                ["teamid:Y5PE65HELJ"],
                callerTeamID: team) == .allowed)
        }
    }
}
#endif
