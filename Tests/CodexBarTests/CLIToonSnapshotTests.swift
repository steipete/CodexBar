import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

/// TOON is a presentation-only serializer over the existing `usage --format json` payload, so these
/// pin the exact rendered document for a fixture payload and assert the emitted field names match
/// the JSON schema one-for-one.
struct CLIToonSnapshotTests {
    @Test
    func `renders a fixture usage payload as an exact TOON document`() throws {
        let toon = try ToonFormatter.encode(Self.makeFixturePayload())

        #expect(toon == """
        [1]:
          - provider: claude
            account: work
            version: 1.2.3
            source: oauth
            usage:
              primary:
                usedPercent: 7
                windowMinutes: 300
              secondary:
                usedPercent: 42.5
                windowMinutes: 10080
              tertiary: null
              details[2]:
                - title: Usage summary
                  rows[2]{label,value}:
                    Requests,"120"
                    Tokens,4.2k
                - title: Extra usage
                  rows[2]:
                    - label: Spend
                      value: $5.00
                      secondaryValue: of $20.00
                    - label: Balance
                      value: $100.00
              updatedAt: "2026-02-02T02:40:00Z"
              identity:
                providerID: claude
                accountEmail: dev@example.com
                loginMethod: OAuth
              accountEmail: dev@example.com
              loginMethod: OAuth
        """)
    }

    /// Agents must be able to switch `--format json` to `--format toon` without re-mapping fields, so
    /// TOON may not rename, drop, or invent a key relative to the JSON encoding of the same payload.
    /// Key *order* is deliberately not compared: `JSONEncoder` emits keyed containers in dictionary
    /// order (and sorts them under `--pretty`), while TOON preserves the stable `CodingKeys` order.
    @Test
    func `TOON emits the same field names as the JSON encoding of the same payload`() throws {
        let payload = try Self.makeFixturePayload()
        let json = try #require(CodexBarCLI.encodeJSON(payload, pretty: false))
        let toon = ToonFormatter.encode(payload)

        let jsonKeys = try Self.jsonFieldNames(in: JSONSerialization.jsonObject(with: Data(json.utf8)))
        let toonKeys = Self.toonFieldNames(in: toon)

        #expect(!jsonKeys.isEmpty)
        #expect(toonKeys == jsonKeys)
    }

    private static func makeFixturePayload() throws -> [ProviderPayload] {
        let uniformRows = try ProviderDetailSection(
            title: "Usage summary",
            rows: [
                ProviderDetailSection.Row(label: "Requests", value: "120"),
                ProviderDetailSection.Row(label: "Tokens", value: "4.2k"),
            ])
        // One row omits `secondaryValue`, so this section must stay in list form rather than
        // collapsing into a table that would fabricate a value for the missing field.
        let mixedRows = try ProviderDetailSection(
            title: "Extra usage",
            rows: [
                ProviderDetailSection.Row(label: "Spend", value: "$5.00", secondaryValue: "of $20.00"),
                ProviderDetailSection.Row(label: "Balance", value: "$100.00"),
            ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 7, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 42.5, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            details: [uniformRows, mixedRows],
            updatedAt: Date(timeIntervalSince1970: 1_770_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "dev@example.com",
                accountOrganization: nil,
                loginMethod: "OAuth"))
        return [
            ProviderPayload(
                provider: .claude,
                account: "work",
                version: "1.2.3",
                source: "oauth",
                status: nil,
                usage: snapshot,
                credits: nil,
                antigravityPlanInfo: nil,
                openaiDashboard: nil,
                error: nil),
        ]
    }

    private static func jsonFieldNames(in value: Any) -> Set<String> {
        switch value {
        case let object as [String: Any]:
            object.reduce(into: Set(object.keys)) { names, entry in
                names.formUnion(self.jsonFieldNames(in: entry.value))
            }
        case let array as [Any]:
            array.reduce(into: Set<String>()) { names, element in
                names.formUnion(self.jsonFieldNames(in: element))
            }
        default:
            []
        }
    }

    /// Collects `key:`, `key[N]:`, and tabular `key[N]{field,field}:` names from rendered TOON.
    /// Table data lines carry no keys, so they are skipped.
    private static func toonFieldNames(in toon: String) -> Set<String> {
        var names: Set<String> = []
        for rawLine in toon.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") {
                line = String(line.dropFirst(2))
            }
            guard let match = line.firstMatch(of: /^([A-Za-z_][A-Za-z0-9_]*)(?:\[\d+\])?(?:\{([^}]*)\})?:/) else {
                continue
            }
            names.insert(String(match.1))
            guard let fields = match.2 else { continue }
            names.formUnion(fields.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        }
        return names
    }
}
