import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct ToonFormatterTests {
    private struct Simple: Encodable {
        let name: String
        let count: Int
        let ratio: Double
        let active: Bool
        let note: String?
    }

    @Test
    func `renders a flat object as key colon value lines`() {
        let value = Simple(name: "claude", count: 3, ratio: 93.0, active: true, note: nil)
        let toon = ToonFormatter.encode(value)

        #expect(toon.contains("name: claude"))
        #expect(toon.contains("count: 3"))
        #expect(toon.contains("ratio: 93"))
        #expect(toon.contains("active: true"))
        #expect(!toon.contains("note"))
    }

    @Test
    func `collapses a uniform scalar array into tabular form`() {
        struct Row: Encodable { let id: Int; let label: String }
        struct Wrapper: Encodable { let rows: [Row] }
        let value = Wrapper(rows: [Row(id: 1, label: "Ada"), Row(id: 2, label: "Bob")])

        let toon = ToonFormatter.encode(value)

        #expect(toon == """
        rows[2]{id,label}:
          1,Ada
          2,Bob
        """)
    }

    @Test
    func `falls back to list form instead of fabricating null for an omitted optional field`() {
        // `encodeIfPresent` omits the key entirely when nil -- row 2 never has a `note` field in the
        // source JSON. Collapsing to tabular form would require inventing a `null` cell for it, which
        // does not round-trip back to "key absent". List form must be used instead, and row 2 must not
        // mention `note` at all.
        struct Row: Encodable {
            let id: Int
            let note: String?
            enum CodingKeys: String, CodingKey { case id, note }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(self.id, forKey: .id)
                try container.encodeIfPresent(self.note, forKey: .note)
            }
        }
        struct Wrapper: Encodable { let rows: [Row] }
        let value = Wrapper(rows: [Row(id: 1, note: "hi"), Row(id: 2, note: nil)])

        let toon = ToonFormatter.encode(value)

        #expect(!toon.contains("{"), "differing field sets must not collapse into a tabular header")
        #expect(!toon.contains("null"), "an omitted optional field must not be fabricated as null")
        #expect(toon.contains("note: hi"))
        #expect(toon == """
        rows[2]:
          - id: 1
            note: hi
          - id: 2
        """)
    }

    @Test
    func `falls back to list form when array items are not uniform scalars`() {
        struct Inner: Encodable { let x: Int }
        struct Row: Encodable { let id: Int; let inner: Inner }
        struct Wrapper: Encodable { let rows: [Row] }
        let value = Wrapper(rows: [Row(id: 1, inner: Inner(x: 9)), Row(id: 2, inner: Inner(x: 8))])

        let toon = ToonFormatter.encode(value)

        #expect(toon == """
        rows[2]:
          - id: 1
            inner:
              x: 9
          - id: 2
            inner:
              x: 8
        """)
    }

    @Test
    func `renders a primitive array inline`() {
        struct Wrapper: Encodable { let tags: [String] }
        let toon = ToonFormatter.encode(Wrapper(tags: ["admin", "ops", "dev"]))

        #expect(toon == "tags[3]: admin,ops,dev")
    }

    @Test
    func `renders an empty array explicitly`() {
        struct Wrapper: Encodable { let tags: [String] }
        let toon = ToonFormatter.encode(Wrapper(tags: []))

        #expect(toon == "tags: []")
    }

    @Test
    func `quotes strings that collide with delimiters keywords or numeric syntax`() {
        struct Wrapper: Encodable { let a: String; let b: String; let c: String; let d: String }
        let value = Wrapper(a: "hello, world", b: "true", c: "42", d: "-negative")
        let toon = ToonFormatter.encode(value)

        #expect(toon.contains(#"a: "hello, world""#))
        #expect(toon.contains(#"b: "true""#))
        #expect(toon.contains(#"c: "42""#))
        #expect(toon.contains(#"d: "-negative""#))
    }

    @Test
    func `fails closed instead of fabricating zero for a NaN or infinite double`() {
        struct Wrapper: Encodable { let usedPercent: Double }

        // A non-finite provider value must not silently render as a valid-looking `0`, which would
        // misrepresent invalid usage/cost data as "no usage". `JSONEncoder` rejects these the same
        // way (EncodingError.invalidValue, swallowed by the CLI's `try?` into "print nothing"); TOON
        // must fail the same way rather than diverge from the documented same-payload contract.
        #expect(ToonFormatter.encode(Wrapper(usedPercent: .nan)).isEmpty)
        #expect(ToonFormatter.encode(Wrapper(usedPercent: .infinity)).isEmpty)
        #expect(ToonFormatter.encode(Wrapper(usedPercent: -.infinity)).isEmpty)

        // Sanity: the same shape with a finite value still renders normally.
        #expect(!ToonFormatter.encode(Wrapper(usedPercent: 42)).isEmpty)
    }

    @Test
    func `NaN and infinity are rejected identically by the JSON path this formatter mirrors`() {
        struct Wrapper: Encodable { let usedPercent: Double }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        #expect(throws: (any Error).self) { try encoder.encode(Wrapper(usedPercent: .nan)) }
        #expect(throws: (any Error).self) { try encoder.encode(Wrapper(usedPercent: .infinity)) }
    }

    @Test
    func `encodes dates as ISO8601 strings matching the JSON formatter`() {
        struct Wrapper: Encodable { let updatedAt: Date }
        let date = Date(timeIntervalSince1970: 0)
        let toon = ToonFormatter.encode(Wrapper(updatedAt: date))

        // ISO8601 timestamps contain colons, which TOON's quoting rule always requires quoting for
        // (colon is reserved for key:value separators), regardless of the active delimiter.
        #expect(toon == #"updatedAt: "1970-01-01T00:00:00Z""#)
    }

    @Test
    func `renders provider usage payloads with tabular detail rows`() throws {
        let section = try ProviderDetailSection(
            title: "Usage summary",
            rows: [
                ProviderDetailSection.Row(label: "Requests", value: "120", secondaryValue: nil),
                ProviderDetailSection.Row(label: "Tokens", value: "4.2k", secondaryValue: nil),
            ])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 7, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            details: [section],
            updatedAt: Date(timeIntervalSince1970: 0))
        let payload = [
            ProviderPayload(
                provider: .claude,
                account: nil,
                version: nil,
                source: "fixture",
                status: nil,
                usage: snapshot,
                credits: nil,
                antigravityPlanInfo: nil,
                openaiDashboard: nil,
                error: nil),
        ]

        let toon = ToonFormatter.encode(payload)

        #expect(toon.contains("[1]:"))
        #expect(toon.contains("- provider: claude"))
        #expect(toon.contains("rows[2]{label,value}:"))
        // "120" is quoted because it's a numeric-looking string, distinguishing it from an actual number.
        #expect(toon.contains(#"Requests,"120""#))
        #expect(toon.contains("Tokens,4.2k"))
        #expect(toon.contains("usedPercent: 7"))
    }

    @Test
    func `usage --format toon resolves output preferences with toon requested`() {
        let output = CodexBarCLI.resolveUsageOutputPreferences(from: ParsedValues(
            positional: [],
            options: ["format": ["toon"]],
            flags: []))

        #expect(output.format == .json)
        #expect(output.toonRequested)
        #expect(output.usesJSONOutput)
    }

    @Test
    func `usage --format json does not request toon`() {
        let output = CodexBarCLI.resolveUsageOutputPreferences(from: ParsedValues(
            positional: [],
            options: ["format": ["json"]],
            flags: []))

        #expect(output.format == .json)
        #expect(!output.toonRequested)
    }

    @Test
    func `explicit toon format wins over a json shortcut in parsed values`() {
        let output = CodexBarCLI.resolveUsageOutputPreferences(from: ParsedValues(
            positional: [],
            options: ["format": ["toon"]],
            flags: ["jsonShortcut"]))

        #expect(output.format == .json)
        #expect(output.toonRequested)
    }

    @Test
    func `a later explicit format overrides an earlier toon request in parsed values`() {
        let jsonWins = CodexBarCLI.resolveUsageOutputPreferences(from: ParsedValues(
            positional: [],
            options: ["format": ["toon", "json"]],
            flags: []))

        #expect(jsonWins.format == .json)
        #expect(!jsonWins.toonRequested)

        let toonWins = CodexBarCLI.resolveUsageOutputPreferences(from: ParsedValues(
            positional: [],
            options: ["format": ["json", "toon"]],
            flags: []))

        #expect(toonWins.format == .json)
        #expect(toonWins.toonRequested)
    }

    @Test
    func `early CLI failures render as TOON instead of falling back to JSON`() {
        let toonOutput = CLIOutputPreferences(format: .json, jsonOnly: false, pretty: false, toonRequested: true)
        let errorPayload = CodexBarCLI.makeCLIErrorProviderPayload(
            message: "Error: --source must be auto|web|cli|oauth|api.",
            code: .failure,
            kind: .args)

        let rendered = CodexBarCLI.renderProviderPayloads([errorPayload], output: toonOutput)

        #expect(rendered.contains("error:"))
        #expect(rendered.contains(#"message: "Error: --source must be auto|web|cli|oauth|api.""#))
        #expect(!rendered.contains("{"), "TOON error output should not fall back to a JSON object literal")
    }

    @Test
    func `early CLI failures still render as JSON when toon was not requested`() {
        let jsonOutput = CLIOutputPreferences(format: .json, jsonOnly: false, pretty: false)
        let errorPayload = CodexBarCLI.makeCLIErrorProviderPayload(
            message: "Nope",
            code: .failure,
            kind: .args)

        let rendered = CodexBarCLI.renderProviderPayloads([errorPayload], output: jsonOutput)

        #expect(rendered.hasPrefix("["))
        #expect(rendered.contains(#""message":"Nope""#))
    }
}
