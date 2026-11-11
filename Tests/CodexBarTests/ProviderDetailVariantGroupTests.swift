import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ProviderDetailVariantGroupTests {
    private static func section(_ title: String, variant: [String]? = nil) throws -> ProviderDetailSection {
        try ProviderDetailSection(
            title: title,
            rows: [ProviderDetailSection.Row(label: "Row", value: "1")],
            variant: variant)
    }

    @Test
    func `consecutive variant sections fold into one group between ordinary sections`() throws {
        let sections = try [
            Self.section("Spend"),
            Self.section("Model month", variant: ["Model", "Month"]),
            Self.section("Model week", variant: ["Model", "Week"]),
            Self.section("Workspace month", variant: ["Workspace", "Month"]),
            Self.section("Notes"),
            Self.section("Single", variant: ["Only"]),
            // A different label count, and a repeated variant, each start a new group.
            Self.section("Pair", variant: ["A", "B"]),
            Self.section("Pair again", variant: ["A", "B"]),
        ]
        let blocks = ProviderDetailBlock.blocks(sections)
        #expect(blocks.count == 6)
        #expect(blocks[0] == .section(sections[0]))
        #expect(blocks[1] == .group(.init(sections: Array(sections[1...3]))))
        #expect(blocks[2] == .section(sections[4]))
        #expect(blocks[3] == .group(.init(sections: [sections[5]])))
        #expect(blocks[4] == .group(.init(sections: [sections[6]])))
        #expect(blocks[5] == .group(.init(sections: [sections[7]])))

        guard case let .group(group) = blocks[1] else {
            Issue.record("Expected a variant group")
            return
        }
        #expect(group.pickers == [["Model", "Workspace"], ["Month", "Week"]])
    }

    @Test
    func `selection falls back to an existing section`() throws {
        let group = try ProviderDetailVariantGroup(sections: [
            Self.section("Model month", variant: ["Model", "Month"]),
            Self.section("Model week", variant: ["Model", "Week"]),
            Self.section("Workspace month", variant: ["Workspace", "Month"]),
        ])
        #expect(group.selection(nil) == ["Model", "Month"])
        #expect(group.selection(["Model", "Week"]) == ["Model", "Week"])
        // A stored choice that no longer exists, or has another shape, resets to the first section.
        #expect(group.selection(["Workspace", "Week"]) == ["Model", "Month"])
        #expect(group.selection(["Model"]) == ["Model", "Month"])

        #expect(group.selection(["Model", "Month"], choosing: "Week", at: 1) == ["Model", "Week"])
        // Workspace has no week section, so the first section offering Workspace is shown instead.
        #expect(group.selection(["Model", "Week"], choosing: "Workspace", at: 0) == ["Workspace", "Month"])
        #expect(group.selection(["Model", "Week"], choosing: "Day", at: 1) == ["Model", "Week"])
        #expect(group.selection(["Model", "Week"], choosing: "Week", at: 5) == ["Model", "Week"])
    }

    @Test
    func `variant survives coding and is absent from ordinary sections`() throws {
        let variant = try Self.section("Model week", variant: [" Model ", "Week"])
        #expect(variant.variant == ["Model", "Week"])
        let decoded = try JSONDecoder().decode(ProviderDetailSection.self, from: JSONEncoder().encode(variant))
        #expect(decoded == variant)
        let plain = try String(data: JSONEncoder().encode(Self.section("Spend")), encoding: .utf8)
        #expect(plain?.contains("variant") == false)
        #expect(throws: ProviderDetailSection.ValidationError.self) { try Self.section("Empty", variant: []) }
        #expect(throws: ProviderDetailSection.ValidationError.self) {
            try Self.section("Long", variant: ["a", "b", "c", "d"])
        }
    }
}
