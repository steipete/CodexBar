import Foundation
import Testing
@testable import CodexBar

struct MenuBarResetTokenPersistenceTests {
    @Test
    func `historical reset JSON keeps automatic semantics and spelling`() throws {
        let fixtures: [(String, MenuBarLayoutToken, Bool)] = [
            (#"{"resetCountdown":{}}"#, .resetCountdown, false),
            (#"{"resetAbsolute":{}}"#, .resetAbsolute, true),
        ]
        for (json, expected, absolute) in fixtures {
            let token = try JSONDecoder().decode(MenuBarLayoutToken.self, from: Data(json.utf8))
            #expect(token == expected)
            #expect(token.resetWindow == .automatic)
            #expect(token.resetIsAbsolute == absolute)
            #expect(try String(bytes: JSONEncoder().encode(token), encoding: .utf8) == json)
        }
        #expect(MenuBarLayoutToken.icon.resetWindow == nil)
    }

    @Test(arguments: PercentWindow.allCases)
    func `selected reset windows round trip without changing automatic tokens`(window: PercentWindow) throws {
        let layout = MenuBarLayout(lines: [[
            .resetCountdown,
            .windowResetCountdown(window: window),
            .resetAbsolute,
            .windowResetAbsolute(window: window),
        ]])
        let encoded = try MenuBarLayoutPersistence.encoded(layout)
        let decoded = try JSONDecoder().decode(MenuBarLayout.self, from: encoded.current)
        #expect(decoded == layout)
        #expect(decoded.lines[0][1].resetWindow == window)
        #expect(!decoded.lines[0][1].resetIsAbsolute)
        #expect(decoded.lines[0][3].resetWindow == window)
        #expect(decoded.lines[0][3].resetIsAbsolute)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(OldLayout.self, from: encoded.current)
        }
        let legacy = try JSONDecoder().decode(OldLayout.self, from: encoded.legacy)
        #expect(legacy.lines == [[.resetCountdown, .resetAbsolute]])
    }

    @Test
    func `legacy layout projection retains unrelated arrangement`() throws {
        let layout = MenuBarLayout(lines: [
            [.icon, .windowResetCountdown(window: .session), .providerName],
            [.resetAbsolute, .windowResetAbsolute(window: .weekly), .percent(window: .weekly)],
        ])
        let blobs = try MenuBarLayoutPersistence.encoded(layout)
        let legacy = try JSONDecoder().decode(OldLayout.self, from: blobs.legacy)
        #expect(legacy.lines == [[.icon, .providerName], [.resetAbsolute, .percent(window: .weekly)]])
        let currentDecoded = try JSONDecoder().decode(MenuBarLayout.self, from: blobs.current)
        let legacyDecoded = try JSONDecoder().decode(MenuBarLayout.self, from: blobs.legacy)
        #expect(MenuBarLayoutPersistence.preferredLayout(current: currentDecoded, legacy: legacyDecoded) == layout)
        let oldEdit = MenuBarLayout(lines: [[.providerName]])
        #expect(MenuBarLayoutPersistence.preferredLayout(current: currentDecoded, legacy: oldEdit) == oldEdit)
    }

    @Test
    func `provider overrides retain current reset windows and readable legacy layouts`() throws {
        let overrides: [String: MenuBarLayout] = [
            "codex": MenuBarLayout(lines: [[.icon, .windowResetCountdown(window: .weekly)]]),
            "claude": MenuBarLayout(lines: [[.providerName, .windowResetAbsolute(window: .session)]]),
        ]
        let blobs = try MenuBarLayoutPersistence.encodedOverrides(overrides)
        let current = try JSONDecoder().decode([String: MenuBarLayout].self, from: blobs.current)
        let legacy = try JSONDecoder().decode([String: MenuBarLayout].self, from: blobs.legacy)
        let oldReader = try JSONDecoder().decode([String: OldLayout].self, from: blobs.legacy)
        #expect(current == overrides)
        #expect(oldReader["codex"]?.lines == [[.icon]])
        #expect(oldReader["claude"]?.lines == [[.providerName]])
        #expect(MenuBarLayoutPersistence.preferredOverrides(current: current, legacy: legacy) == overrides)
    }

    @Test(arguments: PercentWindow.allCases)
    func `legacy conditional projection omits either selected reset branch and preserves other rules`(
        window: PercentWindow) throws
    {
        let retained = self.rule(thenToken: .resetCountdown, elseToken: .hidden)
        let newThen = self.rule(thenToken: .windowResetCountdown(window: window), elseToken: .resetAbsolute)
        let newElse = self.rule(thenToken: .resetCountdown, elseToken: .windowResetAbsolute(window: window))
        let library = [retained, newThen, newElse]
        let blobs = try MenuBarLayoutPersistence.encodedLibrary(library)
        let current = try JSONDecoder().decode([MenuBarLayoutConditional].self, from: blobs.current)
        let legacy = try JSONDecoder().decode([MenuBarLayoutConditional].self, from: blobs.legacy)
        let oldReader = try JSONDecoder().decode([OldConditional].self, from: blobs.legacy)
        #expect(current == library)
        #expect(legacy == [retained])
        #expect(oldReader.map(\.id) == [retained.id])
        #expect(oldReader.first?.thenToken == .resetCountdown)
        #expect(oldReader.first?.elseToken == .hidden)
        #expect(MenuBarLayoutPersistence.preferredLibrary(current: current, legacy: legacy) == library)
    }

    private func rule(thenToken: MenuBarLayoutToken, elseToken: MenuBarLayoutToken)
        -> MenuBarLayoutConditional
    {
        MenuBarLayoutConditional(
            clauses: [MenuBarConditionalClause(
                combinator: nil,
                predicate: MenuBarConditionalPredicate(metric: .weekly, comparison: .greaterThan, threshold: 80))],
            thenToken: thenToken,
            elseToken: elseToken)
    }
}

/// The pre-window-reset decoder surface used by these fixtures. Unknown enum cases must still throw;
/// decoding the projections with today's token type alone would not establish downgrade compatibility.
private enum OldResetToken: Codable, Equatable {
    case icon
    case providerName
    case percent(window: PercentWindow)
    case resetCountdown
    case resetAbsolute
    case hidden
}

private struct OldLayout: Decodable {
    let lines: [[OldResetToken]]
}

private struct OldConditional: Decodable {
    let id: UUID
    let thenToken: OldResetToken
    let elseToken: OldResetToken
}
