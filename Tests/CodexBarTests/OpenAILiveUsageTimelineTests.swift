import CodexBarCore
import Foundation
import Observation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct OpenAILiveUsageTimelineTests {
    @Test
    func `live display clocks stop on close and resume on presentation`() async {
        let model = OpenAILiveUsageModel(
            environment: { [:] },
            fetchLimits: { _ in throw OpenAILiveUsageError.missingCredential },
            fetch: { _, _ in throw OpenAILiveUsageError.missingCredential })
        let view = OpenAILiveUsageView(model: model, openSettings: {})
        let now = Date()
        func entries() -> [Date] {
            Array(OpenAILiveUsageTimelineSchedule(model: model).entries(from: now, mode: .normal).prefix(3))
        }
        #expect(entries().isEmpty)
        model.start()
        await model.waitForRefresh()
        let active = entries()
        #expect(active.count == 3)
        await model.waitForLimitsRefresh()
        let invalidations = LockIsolated(false)
        withObservationTracking {
            _ = view.body
        } onChange: {
            invalidations.setValue(true)
        }
        model.stop()
        #expect(!invalidations.value)
        #expect(entries().isEmpty)
        model.start()
        #expect(entries().count == 3)
        model.stop()
    }
}
