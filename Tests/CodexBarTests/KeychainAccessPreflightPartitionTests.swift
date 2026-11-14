import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import Security

struct KeychainAccessPreflightPartitionTests {
    static func description(_ partitions: [String]) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Partitions": partitions], format: .xml, options: 0)
        return data.map { String(format: "%02x", $0) }.joined()
    }

    @Test
    func `partition membership uses whole team entries and fails closed on unknown identity`() throws {
        let descriptions = try [Self.description(["teamid:OTHER", "apple:", "apple-tool:"])]
        #expect(KeychainAccessPreflight
            .evaluatePartitionList(descriptions: descriptions, callerTeam: "OURS") == .rejected)
        #expect(KeychainAccessPreflight
            .evaluatePartitionList(descriptions: descriptions, callerTeam: "OTHER") == .allowed)
        #expect(KeychainAccessPreflight
            .evaluatePartitionList(descriptions: descriptions, callerTeam: "OTHER2") == .rejected)
        #expect(KeychainAccessPreflight
            .evaluatePartitionList(descriptions: descriptions, callerTeam: nil) == .indeterminate)
        #expect(KeychainAccessPreflight.evaluatePartitionList(descriptions: [], callerTeam: nil) == .allowed)
        #expect(KeychainAccessPreflight
            .evaluatePartitionList(descriptions: ["not hex"], callerTeam: "OURS") == .indeterminate)
        let validDescription = try Self.description(["teamid:OURS"])
        #expect(KeychainAccessPreflight.evaluatePartitionList(
            descriptions: [validDescription, "not hex"], callerTeam: "OURS") == .indeterminate)
    }

    /// Only in-memory ACL objects; no Keychain item is created or read.
    @available(macOS, deprecated: 10.10)
    private static func access(entries: [(CFString, String)]) throws -> SecAccess {
        var access: SecAccess?
        #expect(SecAccessCreate("partition-test" as CFString, [] as CFArray, &access) == errSecSuccess)
        let created = try #require(access)
        for (authorization, description) in entries {
            var acl: SecACL?
            #expect(SecACLCreateWithSimpleContents(
                created, nil, description as CFString, SecKeychainPromptSelector(), &acl) == errSecSuccess)
            #expect(try SecACLUpdateAuthorizations(#require(acl), [authorization] as CFArray) == errSecSuccess)
        }
        return created
    }

    @Test
    @available(macOS, deprecated: 10.10)
    func `native ACL inspection skips wildcard descriptions but enforces partition entries`() throws {
        let access = try Self.access(entries: [
            (kSecACLAuthorizationAny, "not a partition payload"),
            (kSecACLAuthorizationPartitionID, Self.description(["teamid:OTHER"])),
        ])
        #expect(KeychainAccessPreflight.evaluatePartitionList(access: access, callerTeam: "OURS") == .rejected)
        #expect(KeychainAccessPreflight.evaluatePartitionList(access: access, callerTeam: "OTHER") == .allowed)
        let legacy = try Self.access(entries: [(kSecACLAuthorizationAny, "legacy")])
        #expect(KeychainAccessPreflight.evaluatePartitionList(access: legacy, callerTeam: nil) == .allowed)
        let malformed = try Self.access(entries: [(kSecACLAuthorizationPartitionID, "not hex")])
        #expect(KeychainAccessPreflight.evaluatePartitionList(access: malformed, callerTeam: "OURS") == .indeterminate)
    }

    @Test
    func `partition-aware checks do not reuse decrypt-only memo entries or previous grants`() async throws {
        let descriptions = try LockIsolated<[String]>([Self.description(["teamid:OURS"])])
        let checks = LockIsolated(0)
        try await KeychainAccessPreflight.withPartitionCheckOverrideForTesting { _, _, requirePartition in
            checks.setValue(checks.value + 1)
            guard requirePartition else { return .allowed }
            return KeychainAccessPreflight.evaluatePartitionList(
                descriptions: descriptions.value, callerTeam: "OURS") == .allowed ? .allowed : .interactionRequired
        } operation: {
            func check(_ requirePartition: Bool) -> KeychainAccessPreflight.Outcome {
                KeychainAccessPreflight.checkGenericPassword(
                    service: "partition-test", account: nil, requirePartition: requirePartition)
            }
            KeychainAccessPreflight.withMemoizedGenericPasswordChecks {
                #expect(check(false) == .allowed)
                #expect(check(true) == .allowed)
                #expect(check(true) == .allowed)
            }
            #expect(checks.value == 2)
            try descriptions.setValue([Self.description(["teamid:OTHER"])])
            KeychainAccessPreflight.withMemoizedGenericPasswordChecks {
                #expect(check(false) == .allowed)
                #expect(check(true) == .interactionRequired)
            }
            #expect(checks.value == 4)
        }
    }
}
#endif
