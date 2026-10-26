import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginDetailPaceTests {
    @Test(arguments: ProviderPluginTransportTests.engines)
    func `plugin pace survives snapshot serialization`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try ProviderPluginTransportTests.runtime(engine, body: """
        return { details: [{ rows: [{ label: 'Weekly', value: '60%', progress: 0.6, pace: 0.5 }] }] };
        """)
        let row = try await runtime.fetchUsage().details[0].rows[0]
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        let progress = try #require(json["progress"] as? [String: Any])
        #expect(progress["expectedUsed"] as? Double == 0.5)
    }
}
