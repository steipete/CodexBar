import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginMenuBarItemsTests {
    @Test(arguments: ProviderPluginTransportTests.engines)
    func `menu bar items reference measured windows and survive snapshot copies`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
        if (ctx.env.supportsMenuBarItems !== true) throw new Error('missing support');
        return { extraWindows: [
          {id:'claude-week',title:'Claude',window:{usedPercent:25,windowMinutes:10080}},
          {id:'codex-week',title:'Codex',window:{usedPercent:100,windowMinutes:10080}}],
          menuBarItems:[{title:'Claude',iconProvider:'claude',windowID:'claude-week'},
                       {title:'Codex',iconProvider:'codex',windowID:'codex-week'},
                       {title:'Unknown',iconProvider:'zai',windowID:'missing'}] };
        """)
        let snapshot = try await runtime.fetchUsage()
        #expect(snapshot.menuBarItems.map(\.title) == ["Claude", "Codex", "Unknown"])
        #expect(snapshot.menuBarItems[0].window(in: snapshot)?.usedPercent == 25)
        #expect(snapshot.menuBarItems[1].window(in: snapshot)?.usedPercent == 100)
        #expect(snapshot.menuBarItems[2].window(in: snapshot) == nil)
        #expect(snapshot.menuBarItems[0].iconProvider == .claude)
        let data = try JSONEncoder().encode(snapshot.with(details: []))
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(decoded.menuBarItems.map(\.windowID) == snapshot.menuBarItems.map(\.windowID))
        #expect(decoded.menuBarItems[0].window(in: decoded)?.usedPercent == 25)
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `menu bar items have bounded strict metadata`(engine: ProviderPluginEngineKind) async throws {
        let tooMany = Array(repeating: "{title:'Quota'}", count: 9).joined(separator: ",")
        for value in [
            "42",
            "{}",
            "[true]",
            "[{}]",
            "[{title:''}]",
            "[{title:'Quota',windowID:42}]",
            "[{title:'Quota',iconProvider:'unknown'}]",
            "[{title:'Quota',url:'https://example.com'}]",
            "[" + tooMany + "]",
            "[{title:'" + String(repeating: "x", count: 121) + "'}]",
        ] {
            let runtime = try ProviderPluginTransportTests.runtime(
                engine,
                body: "return {empty:true,menuBarItems:\(value)};")
            await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
        }
        for field in ["", "menuBarItems:null,", "menuBarItems:[],"] {
            let runtime = try ProviderPluginTransportTests.runtime(engine, body: "return {\(field)empty:true};")
            let snapshot = try await runtime.fetchUsage()
            #expect(snapshot.menuBarItems.isEmpty)
            let json = try #require(JSONSerialization
                .jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
            #expect(json["menuBarItems"] == nil)
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `unavailable item references never use another quota`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
        return {extraWindows:[{id:'hidden',title:'Unavailable',usageKnown:false,window:{usedPercent:0}}],
          menuBarItems:[{title:'Absent'},{title:'Hidden',windowID:'hidden'}]};
        """)
        let snapshot = try await runtime.fetchUsage()
        #expect(snapshot.menuBarItems.allSatisfy { $0.window(in: snapshot) == nil })
    }
}
